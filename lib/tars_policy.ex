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

      Tars.Fleet.spawn(key, config: config, policy: {TarsPolicy, policy})

  A policy is a `Tars.Policy` named as `{TarsPolicy, policy}`. It is plain
  data, so it is written to the store with the agent it governs and decides the
  same way on whichever node holds that agent.

  ## Deciding

  Every rule whose `TarsPolicy.Pattern` names a call speaks for it, and the
  strictest of them decides: `:deny` over `:ask` over `:allow`. A call no rule
  names is decided by `:default`, which is `:allow` unless set. A rule's
  message is what a person is asked, or what the model is told it may not do.

  ## Written down

  `decode/1` reads the map form a file or a request writes a policy in, and
  `encode/1` writes it back:

      allow: [web_search, linear/*]
      ask:
        github/create_*: This opens an issue on GitHub.
      deny: [run_lua]
      default: allow

  `allow`, `ask` and `deny` each take a list of patterns, or a map of pattern
  to message.
  """

  @behaviour Tars.Policy

  alias TarsPolicy.Pattern
  alias TarsPolicy.Rule

  defstruct name: nil, rules: [], default: :allow

  @type t() :: %__MODULE__{name: String.t() | nil, rules: [Rule.t()], default: Rule.effect()}

  @effects ~w(allow ask deny)
  @keys @effects ++ ["default"]
  @strictness %{deny: 2, ask: 1, allow: 0}

  @doc "What `policy` says about a call to the tool the agent knows as `name`."
  @spec decide(t(), String.t()) :: Tars.Policy.decision()
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

  @impl Tars.Policy
  def authorize(call, _scope, %__MODULE__{} = policy), do: decide(policy, call.name)

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
             {:ok, default} <- effect(Map.get(fields, "default", "allow"), "default") do
          {:ok, %__MODULE__{name: name, rules: rules, default: default}}
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

    Map.put(by_effect, "default", Atom.to_string(policy.default))
  end

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
