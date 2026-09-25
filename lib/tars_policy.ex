defmodule TarsPolicy do
  @moduledoc """
  A policy written as data: the tools an agent may call, the ones that ask a
  person first, and the ones it may not call at all.

      policy =
        TarsPolicy.decode!(%{
          "allow" => ["web_search", "linear/*"],
          "ask" => %{"github/create_*" => "This opens an issue on GitHub."},
          "deny" => ["run_lua"],
          "default" => "allow"
        })

      Tars.Fleet.spawn(key, config: config, hooks: TarsPolicy.hooks(policy))

  A policy's rules are a `Tars.Hook`, named for the policy. It is plain data,
  so it is written to the store with the agent it governs and decides the
  same way on whichever node holds that agent.

  ## Budgets

  A policy with a `TarsPolicy.Budget` limits what the agent spends on model
  calls. `hooks/1` gives the budget a hook of its own, after the rules, named
  for the policy with `/budget` added.

  ## Deciding

  Every rule whose `TarsPolicy.Pattern` names a call speaks for it, and the
  strictest of them decides: `:deny` over `:ask` over `:allow`. A call no rule
  names is decided by `:default`, which is `:allow` unless set. A rule's
  message is what a person is asked, or what the model is told it may not do.
  The rules allow every model call.

  ## Written down

  `decode/1` reads the map form a file or a request writes a policy in, and
  `encode/1` writes it back:

      allow: [web_search, linear/*]
      ask:
        github/create_*: This opens an issue on GitHub.
      deny: [run_lua]
      default: allow

  `allow`, `ask` and `deny` each take a list of patterns, or a map of pattern
  to message. `budget` takes what `TarsPolicy.Budget` describes.
  """

  @behaviour Tars.Hook

  alias Tars.Call
  alias Tars.Hook
  alias TarsPolicy.Budget
  alias TarsPolicy.Pattern
  alias TarsPolicy.Rule

  defstruct name: nil, rules: [], default: :allow, budget: nil

  @type t() :: %__MODULE__{
          name: String.t() | nil,
          rules: [Rule.t()],
          default: Rule.effect(),
          budget: Budget.t() | nil
        }

  @typedoc "What a policy says about one tool."
  @type decision() :: :allow | {:ask, String.t()} | {:deny, String.t()}

  @effects ~w(allow ask deny)
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

  @doc "What `policy` says about a call to the tool the agent knows as `name`."
  @spec decide(t(), String.t()) :: decision()
  def decide(%__MODULE__{} = policy, name) when is_binary(name) do
    case Enum.filter(policy.rules, &Rule.match?(&1, name)) do
      [] ->
        answer(policy.default, nil, name)

      rules ->
        rules
        |> Enum.max_by(&Map.fetch!(@strictness, &1.effect))
        |> then(&answer(&1.effect, &1.message, name))
    end
  end

  @impl Tars.Hook
  def init(%__MODULE__{} = policy), do: policy
  def init(%{} = fields), do: decode!(fields)

  @impl Tars.Hook
  def call(%Call{target: %Call.Tool{name: name}} = call, %__MODULE__{} = policy) do
    case decide(policy, name) do
      :allow -> call
      {:ask, prompt} -> Call.ask(call, prompt)
      {:deny, reason} -> Call.deny(call, reason)
    end
  end

  def call(%Call{} = call, %__MODULE__{}), do: call

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

  def decode(_fields, _name), do: {:error, "is a set of rules: allow, ask, deny and default"}

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
      for effect <- [:allow, :ask, :deny],
          rules = Enum.filter(policy.rules, &(&1.effect == effect)),
          rules != [],
          into: %{},
          do: {Atom.to_string(effect), written(rules)}

    by_effect
    |> Map.put("default", Atom.to_string(policy.default))
    |> then(&if(policy.budget, do: Map.put(&1, "budget", Budget.encode(policy.budget)), else: &1))
  end

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
         {:ok, effect} <- effect(key, key) do
      {:ok, %Rule{effect: effect, pattern: pattern, message: message}}
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
