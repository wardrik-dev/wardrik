defmodule WardrikPolicy do
  @moduledoc """
  A policy written as data: the tools an agent may call, the ones that ask a
  person first, and the ones it may not call at all.

      policy =
        WardrikPolicy.decode!(%{
          "allow" => ["web_search", "linear/*"],
          "ask" => %{"github/create_*" => "This opens an issue on GitHub."},
          "deny" => ["run_lua"],
          "default" => "allow"
        })

      Wardrik.Fleet.spawn(key, config: config, hooks: WardrikPolicy.hooks(policy))

  A policy's rules are a `Wardrik.Hook`, named for the policy. It is plain data,
  so it is written to the store with the agent it governs and decides the
  same way on whichever node holds that agent.

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

  ## Allowing by name

  A call an `allow` rule allows is allowed by name, with an
  `:allow` decision, which is what a gated tool's call waits for (see
  `Wardrik.Tool.Annotations`). One allowed only by `default: allow` is not, so
  a gated tool asks under a policy that names nothing, as it does under none.

  ## After content from outside

  Once a run has read content from outside, a gated tool's call waits on a
  person however the rules allowed it, since what the run read may be what
  asked for it. An `allow_after_outside` rule allows by name as `allow` does,
  and holds after that too: it is for a tool whose calls may follow what a
  stranger wrote, because the agent reaches nothing they could take, or the
  tool can do little harm.

      allow: [linear/*]
      allow_after_outside: [github/add_labels]

  The call is allowed after outside content only where such rules allow the
  whole of it, or every one of its subjects.

  ## Written down

  `decode/1` reads the map form a file or a request writes a policy in, and
  `encode/1` writes it back:

      allow: [web_search, linear/*]
      ask:
        github/create_*: This opens an issue on GitHub.
      deny: [run_lua]
      default: allow

  `allow`, `allow_after_outside`, `ask` and `deny` each take a list of
  patterns, or a map of pattern to message. `budget` takes what
  `WardrikPolicy.Budget` describes.
  """

  @behaviour Wardrik.Hook

  alias Wardrik.Call
  alias Wardrik.Hook
  alias WardrikPolicy.Budget
  alias WardrikPolicy.Pattern
  alias WardrikPolicy.Rule

  defstruct name: nil, rules: [], default: :allow, budget: nil

  @type t() :: %__MODULE__{
          name: String.t() | nil,
          rules: [Rule.t()],
          default: Rule.effect(),
          budget: Budget.t() | nil
        }

  @typedoc "What a policy says about one tool."
  @type decision() :: :allow | {:ask, String.t()} | {:deny, String.t()}

  @effects ~w(allow allow_after_outside ask deny)
  @keys @effects ++ ["default", "budget"]
  @strictness %{deny: 2, ask: 1, allow: 0}

  @doc """
  The hooks `policy` is: its rules, named for the policy or `policy` where it
  has no name, then its budget where it has one.
  """
  @spec hooks(t()) :: [Hook.t()]
  def hooks(%__MODULE__{} = policy) do
    name = policy.name || "policy"
    rules = Hook.new(name, __MODULE__, %{policy | budget: nil})

    case policy.budget do
      nil -> [rules]
      budget -> [rules, Hook.new(name <> "/budget", Budget, budget)]
    end
  end

  @doc """
  What `policy` says about a call to the tool the agent knows as `name`,
  acting on `subjects`.
  """
  @spec decide(t(), String.t(), [String.t()]) :: decision()
  def decide(%__MODULE__{} = policy, name, subjects \\ [])
      when is_binary(name) and is_list(subjects) do
    case verdict(policy, name, subjects) do
      {:allow, _how} -> :allow
      decision -> decision
    end
  end

  # What the rules say, with `{:allow, :named}` for a call they allow, apart
  # from one `:default` allows, and `{:allow, :after_outside}` for one they
  # allow after content from outside too.
  defp verdict(policy, name, subjects) do
    whole = Enum.filter(policy.rules, &Rule.match?(&1, name))
    each = for subject <- subjects, do: Enum.filter(policy.rules, &Rule.match?(&1, name, subject))

    speaking = whole ++ Enum.concat(each)

    case Enum.max_by(speaking, &Map.fetch!(@strictness, &1.effect), fn -> nil end) do
      nil ->
        answer(policy.default, nil, name)

      %Rule{effect: :allow} ->
        cond do
          covered?(whole, each, & &1.after_outside) -> {:allow, :after_outside}
          covered?(whole, each, fn _rule -> true end) -> {:allow, :named}
          true -> answer(policy.default, nil, name)
        end

      %Rule{effect: effect, message: message} ->
        answer(effect, message, name)
    end
  end

  # Whether rules that pass `test` speak for the whole of the call, or for
  # every one of its subjects.
  defp covered?(whole, each, test),
    do: Enum.any?(whole, test) or (each != [] and Enum.all?(each, &Enum.any?(&1, test)))

  @impl Wardrik.Hook
  def init(%__MODULE__{} = policy), do: policy
  def init(%{} = fields), do: decode!(fields)

  @impl Wardrik.Hook
  def call(%Call{target: %Call.Tool{name: name} = tool}, %__MODULE__{} = policy) do
    case verdict(policy, name, Map.get(tool, :subjects, [])) do
      {:allow, :after_outside} -> {:allow, after_outside: true}
      {:allow, :named} -> :allow
      :allow -> :pass
      asked_or_denied -> asked_or_denied
    end
  end

  def call(%Call{}, %__MODULE__{}), do: :pass

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
             {:ok, budget} <- budget(Map.fetch(fields, "budget")) do
          {:ok, %__MODULE__{name: name, rules: rules, default: default, budget: budget}}
        end

      [key | _] ->
        {:error, "#{key} is not a setting; expected one of #{Enum.join(@keys, ", ")}"}
    end
  end

  def decode(_fields, _name),
    do: {:error, "is a set of rules: allow, allow_after_outside, ask, deny and default"}

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
          rules = Enum.filter(policy.rules, &(written_under(&1) == key)),
          rules != [],
          into: %{},
          do: {key, written(rules)}

    by_effect
    |> Map.put("default", Atom.to_string(policy.default))
    |> then(&if(policy.budget, do: Map.put(&1, "budget", Budget.encode(policy.budget)), else: &1))
  end

  defp written_under(%Rule{effect: :allow, after_outside: true}), do: "allow_after_outside"
  defp written_under(%Rule{effect: effect}), do: Atom.to_string(effect)

  defp budget(:error), do: {:ok, nil}
  defp budget({:ok, fields}), do: Budget.decode(fields)

  defp written(rules) do
    if Enum.all?(rules, &is_nil(&1.message)),
      do: Enum.map(rules, &to_string(&1.pattern)),
      else: Map.new(rules, &{to_string(&1.pattern), &1.message})
  end

  defp rules(fields) do
    @effects
    |> Enum.flat_map(fn key ->
      fields |> Map.get(key, []) |> entries() |> Enum.map(&{key, &1})
    end)
    |> Enum.reduce_while({:ok, []}, fn {key, entry}, {:ok, rules} ->
      case rule(key, entry) do
        {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  defp entries(patterns) when is_list(patterns), do: Enum.map(patterns, &{&1, nil})
  defp entries(patterns) when is_map(patterns), do: Enum.to_list(patterns)
  defp entries(other), do: [{other, :not_a_list}]

  defp rule(key, {_pattern, :not_a_list}),
    do: {:error, "#{key} is a list of tool patterns, or a map of pattern to message"}

  defp rule(key, {source, message}) when is_binary(message) or is_nil(message) do
    with {:ok, pattern} <- Pattern.parse(source),
         {:ok, effect} <- effect(String.replace_suffix(key, "_after_outside", ""), key) do
      {:ok,
       %Rule{
         effect: effect,
         pattern: pattern,
         message: message,
         after_outside: key == "allow_after_outside"
       }}
    else
      {:error, reason} -> {:error, "#{key} names #{reason}"}
    end
  end

  defp rule(key, {source, _message}),
    do: {:error, "#{key} gives #{source} a message that is not text"}

  defp effect("allow", _key), do: {:ok, :allow}
  defp effect("ask", _key), do: {:ok, :ask}
  defp effect("deny", _key), do: {:ok, :deny}
  defp effect(_value, key), do: {:error, "#{key} is allow, ask or deny"}
end
