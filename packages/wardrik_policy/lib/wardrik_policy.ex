defmodule WardrikPolicy do
  @moduledoc """
  A policy written as data: the tools an agent may call, the ones that ask a
  person first, and the ones it may not call at all.

  ```elixir
  policy =
    WardrikPolicy.decode!(%{
      "allow" => ["web_search", "linear/*"],
      "ask" => %{"github/create_*" => "This opens an issue on GitHub."},
      "deny" => ["run_lua"],
      "default" => "allow"
    })

  Wardrik.Fleet.spawn(id, config: config, hooks: WardrikPolicy.hooks(policy))
  ```

  A policy's rules are a `Wardrik.Hook`, named for the policy. It is plain data,
  so it is written to the store with the agent it governs and decides the
  same way on whichever node holds that agent.

  The [Policies](policies.md) guide is the file format, every key a policy
  file takes, for whoever writes one.

  ## Budgets

  A policy with a `WardrikPolicy.Budget` limits what the agent spends on model
  calls. `hooks/1` gives the budget a hook of its own, after the rules, named
  for the policy with `/budget` added.

  ## Deciding

  Every rule whose `WardrikPolicy.Pattern` names a call speaks for it, and the
  strictest of them decides: `:deny` over `:ask` over `:allow`. A call no rule
  names is decided by `:default`, which is `:allow` unless set. A rule's
  message is what a person is asked, or what the model is told it may not do.
  The rules allow every model call.

  A rule may name what a call acts on, `write_file(notes/*)`, and speaks then
  for each of the call's subjects it matches (see `c:Wardrik.Tool.subjects/2`).
  A deny or an ask that speaks for any subject decides the call, and the call
  is allowed by the rules only where they allow the whole of it, or every one
  of its subjects; otherwise `:default` decides:

      allow: [shell(git status), shell(git diff *)]
      deny: [shell(git push *)]

  A rule may instead hold conditions on what a call's arguments are, which
  `WardrikPolicy.Condition` describes, and speaks then for the whole of each
  call they hold for. A deny or an ask speaks too for a call it cannot
  check, one that gives an argument it names in a form it cannot compare,
  and an allow does not; a call that leaves the argument out is one no such
  rule speaks for:

      allow: [books/list_*, books/create_bill(amount < 100)]
      deny: [books/*(account = Payroll)]

  ## Allowing by name

  A call an `allow` rule allows is allowed by name, with an
  `:allow` decision, which is what a gated tool's call waits for (see
  `Wardrik.Tool.Annotations`). One allowed only by `default: allow` is not, so
  a gated tool asks under a policy that names nothing, as it does under none.

  ## After what the run has read

  A run carries the `Wardrik.Label`s of what it has read. Once it carries
  `"outside"`, content nobody on the agent's side wrote, a gated tool's call
  waits on a person however the rules allowed it, since what the run read
  may be what asked for it. An `allow_after` rule allows by name as `allow`
  does, and holds after its label too: it is for a tool whose calls may
  follow what a stranger wrote, because the agent reaches nothing they could
  take, or the tool can do little harm.

      allow: [linear/*]
      allow_after:
        outside: [github/add_labels]

  A label the policy names under `allow_after` holds a gated tool's calls the
  same way, and the call is allowed only where, for every such label the run
  carries, `allow_after` rules for it allow the whole of the call, or every
  one of its subjects. A label the policy does not name is carried and
  shown, and holds nothing.

  ## Written down

  `decode/1` reads the map form a file or a request writes a policy in, as
  the guide lists its keys, and `encode/1` writes it back. `budget` takes what
  `WardrikPolicy.Budget` describes, and `judge` what `WardrikPolicy.Judge`
  does.

  ## Judged

  A policy with a `WardrikPolicy.Judge` asks a model questions about each
  call its questions name, and decides by the probability of yes: refuses
  it, asks a person first, or allows it by name where the run has read
  nothing from outside. `hooks/1` gives the judge a hook of its own, after
  the rules, named for the policy with `/judge` added, so its allow never
  lifts a call a rule asks about or denies.
  """

  @behaviour Wardrik.Hook

  alias Wardrik.Call
  alias Wardrik.Hook
  alias WardrikPolicy.Budget
  alias WardrikPolicy.Judge
  alias WardrikPolicy.Pattern
  alias WardrikPolicy.Rule

  defstruct name: nil, rules: [], default: :allow, budget: nil, judge: nil

  @type t() :: %__MODULE__{
          name: String.t() | nil,
          rules: [Rule.t()],
          default: Rule.effect(),
          budget: Budget.t() | nil,
          judge: Judge.t() | nil
        }

  @typedoc "What a policy says about one tool."
  @type decision() :: :allow | {:ask, String.t()} | {:deny, String.t()}

  @effects ~w(allow ask deny)
  @keys @effects ++ ["allow_after", "default", "budget", "judge"]
  @outside "outside"
  @strictness %{deny: 2, ask: 1, allow: 0}

  @doc """
  The hooks `policy` is: its rules, named for the policy or `policy` where it
  has no name, then its judge and its budget where it has them. The budget
  meters under its hook's name, so each budget an agent is held to counts
  apart.
  """
  @spec hooks(t()) :: [Hook.t()]
  def hooks(%__MODULE__{} = policy) do
    name = policy.name || "policy"

    [
      Hook.new(name, __MODULE__, %{policy | budget: nil, judge: nil}),
      policy.judge && Hook.new(name <> "/judge", Judge, policy.judge),
      policy.budget &&
        Hook.new(name <> "/budget", Budget, %{policy.budget | meter: name <> "/budget"})
    ]
    |> Enum.filter(& &1)
  end

  @doc """
  What `policy` says about a call to the tool the agent knows as `name`,
  acting on `subjects`, with `arguments`.
  """
  @spec decide(t(), String.t(), [String.t()], map()) :: decision()
  def decide(%__MODULE__{} = policy, name, subjects \\ [], arguments \\ %{})
      when is_binary(name) and is_list(subjects) and is_map(arguments) do
    case verdict(policy, name, subjects, arguments) do
      {:allow, _how} -> :allow
      decision -> decision
    end
  end

  # What the rules say, with `{:allow, speaking}` for a call they allow by
  # name, apart from one `:default` allows, and the rules that speak for the
  # whole of it and for each subject.
  defp verdict(policy, name, subjects, arguments) do
    whole = Enum.filter(policy.rules, &Rule.whole?(&1, name, arguments))

    each =
      for subject <- subjects, do: Enum.filter(policy.rules, &Rule.subject?(&1, name, subject))

    strictest =
      Enum.max_by(whole ++ Enum.concat(each), &Map.fetch!(@strictness, &1.effect), fn -> nil end)

    case strictest do
      nil -> answer(policy.default, nil, name)
      %Rule{effect: :allow} -> named(policy, name, whole, each)
      %Rule{effect: effect, message: message} -> answer(effect, message, name)
    end
  end

  defp named(policy, name, whole, each) do
    if covered?(whole, each, fn _rule -> true end),
      do: {:allow, {whole, each}},
      else: answer(policy.default, nil, name)
  end

  # A gated call the rules allow waits on a person while its run carries a
  # label the policy holds, unless rules allowing it after that label speak
  # for it.
  defp held(policy, %Call.Tool{gated: true, name: name}, labels, {whole, each}) do
    held = holding(policy)

    case Enum.find(labels, &(&1 in held and not covered?(whole, each, after?(&1)))) do
      nil ->
        :allow

      label ->
        {:ask,
         "#{Pattern.shown(name)} is allowed, but this run has read #{Wardrik.Label.described([label])}, " <>
           "which may be what asked for it."}
    end
  end

  defp held(_policy, _tool, _labels, _speaking), do: :allow

  defp holding(policy),
    do: Enum.uniq([@outside | for(%Rule{after: label} <- policy.rules, label, do: label)])

  defp after?(label), do: &(&1.effect == :allow and &1.after == label)

  # Whether rules that pass `test` speak for the whole of the call, or for
  # every one of its subjects.
  defp covered?(whole, each, test),
    do: Enum.any?(whole, test) or (each != [] and Enum.all?(each, &Enum.any?(&1, test)))

  @impl Wardrik.Hook
  def init(%__MODULE__{} = policy), do: policy
  def init(%{} = fields), do: decode!(fields)

  @impl Wardrik.Hook
  def call(%Call{target: %Call.Tool{name: name} = tool, scope: scope}, %__MODULE__{} = policy) do
    case verdict(policy, name, tool.subjects, tool.arguments) do
      {:allow, speaking} -> held(policy, tool, labels(scope), speaking)
      :allow -> :pass
      asked_or_denied -> asked_or_denied
    end
  end

  def call(%Call{}, %__MODULE__{}), do: :pass

  defp labels(%Wardrik.Scope{labels: labels}), do: labels
  defp labels(nil), do: []

  defp answer(:allow, _message, _name), do: :allow

  defp answer(:ask, message, name),
    do: {:ask, message || "#{Pattern.shown(name)} needs your approval."}

  defp answer(:deny, message, name),
    do: {:deny, message || "#{Pattern.shown(name)} is not allowed for this agent."}

  # -- written down ------------------------------------------------------------

  @doc "The policy a map with string keys writes, named `name`."
  @spec decode(map(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def decode(fields, name \\ nil)

  def decode(fields, name) when is_map(fields) do
    case Map.keys(fields) -- @keys do
      [] ->
        with {:ok, rules} <- rules(fields),
             {:ok, default} <- effect(Map.get(fields, "default", "allow"), "default"),
             {:ok, budget} <- budget(Map.fetch(fields, "budget")),
             {:ok, judge} <- judge(Map.fetch(fields, "judge")) do
          {:ok,
           %__MODULE__{name: name, rules: rules, default: default, budget: budget, judge: judge}}
        end

      [key | _] ->
        {:error, "#{key} is not a setting; expected one of #{Enum.join(@keys, ", ")}"}
    end
  end

  def decode(_fields, _name),
    do: {:error, "is a set of rules: allow, allow_after, ask, deny and default"}

  @doc "The policy a map with string keys writes, raising where it writes none."
  @spec decode!(map(), String.t() | nil) :: t()
  def decode!(fields, name \\ nil) do
    case decode(fields, name) do
      {:ok, policy} -> policy
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "The map `decode/2` reads `policy` back from."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = policy) do
    by_effect =
      for key <- @effects,
          rules =
            Enum.filter(
              policy.rules,
              &(Atom.to_string(&1.effect) == key and is_nil(&1.after))
            ),
          rules != [],
          into: %{},
          do: {key, written(rules)}

    after_labels =
      policy.rules
      |> Enum.filter(& &1.after)
      |> Enum.group_by(& &1.after)
      |> Map.new(fn {label, rules} -> {label, written(rules)} end)

    by_effect
    |> then(&if(after_labels == %{}, do: &1, else: Map.put(&1, "allow_after", after_labels)))
    |> Map.put("default", Atom.to_string(policy.default))
    |> then(&if(policy.budget, do: Map.put(&1, "budget", Budget.encode(policy.budget)), else: &1))
    |> then(&if(policy.judge, do: Map.put(&1, "judge", Judge.encode(policy.judge)), else: &1))
  end

  defp budget(:error), do: {:ok, nil}
  defp budget({:ok, fields}), do: Budget.decode(fields)

  defp judge(:error), do: {:ok, nil}
  defp judge({:ok, fields}), do: Judge.decode(fields)

  defp written(rules) do
    if Enum.all?(rules, &is_nil(&1.message)),
      do: Enum.map(rules, &to_string(&1.pattern)),
      else: Map.new(rules, &{to_string(&1.pattern), &1.message})
  end

  defp rules(fields) do
    with {:ok, after_labels} <- after_labels(Map.get(fields, "allow_after", %{})) do
      @effects
      |> Enum.flat_map(fn key ->
        fields |> Map.get(key, []) |> entries() |> Enum.map(&{key, nil, &1})
      end)
      |> Enum.concat(after_labels)
      |> Enum.reduce_while({:ok, []}, &collect/2)
      |> case do
        {:ok, rules} -> {:ok, Enum.reverse(rules)}
        error -> error
      end
    end
  end

  defp collect({key, label, entry}, {:ok, rules}) do
    case rule(key, label, entry) do
      {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
      {:error, message} -> {:halt, {:error, message}}
    end
  end

  # `allow_after` maps each label to what an `allow` rule takes.
  defp after_labels(labels) when is_map(labels) do
    case Enum.reject(Map.keys(labels), &(is_binary(&1) and &1 != "")) do
      [] ->
        rules =
          for {label, patterns} <- labels,
              entry <- entries(patterns),
              do: {"allow_after #{label}", label, entry}

        {:ok, rules}

      [label | _others] ->
        {:error, "allow_after names #{inspect(label)}, which is not a label"}
    end
  end

  defp after_labels(_other), do: {:error, "allow_after is a map of label to tool patterns"}

  defp entries(patterns) when is_list(patterns), do: Enum.map(patterns, &{&1, nil})
  defp entries(patterns) when is_map(patterns), do: Enum.to_list(patterns)
  defp entries(other), do: [{other, :not_a_list}]

  defp rule(key, _label, {%{} = read, nil}) when map_size(read) == 1 do
    [{before, rest}] = Map.to_list(read)

    {:error,
     "#{key} lists #{before}: #{rest}, which YAML reads as a key and its value; a condition " <>
       "on a value is written with =, and a rule with \": \" in it is quoted whole"}
  end

  defp rule(key, _label, {_pattern, :not_a_list}),
    do: {:error, "#{key} is a list of tool patterns, or a map of pattern to message"}

  defp rule(key, label, {source, message}) when is_binary(message) or is_nil(message) do
    with {:ok, pattern} <- Pattern.parse(source),
         {:ok, effect} <- effect(if(label, do: "allow", else: key), key) do
      {:ok, %Rule{effect: effect, pattern: pattern, message: message, after: label}}
    else
      {:error, reason} -> {:error, "#{key} names #{reason}"}
    end
  end

  defp rule(key, _label, {source, _message}),
    do: {:error, "#{key} gives #{source} a message that is not text"}

  defp effect("allow", _key), do: {:ok, :allow}
  defp effect("ask", _key), do: {:ok, :ask}
  defp effect("deny", _key), do: {:ok, :deny}
  defp effect(_value, key), do: {:error, "#{key} is allow, ask or deny"}
end
