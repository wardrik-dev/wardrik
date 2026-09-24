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

  ## Budgets

  A policy with a `TarsPolicy.Budget` limits what the agent spends on model
  calls, and is a `Tars.LLM.Dispatch` too, named the same way:

      Tars.Fleet.spawn(key, config: config, policy: {TarsPolicy, policy}, dispatch: {TarsPolicy, policy})

  Each call is checked before it is made against what the agent has spent in
  the budget's period, as its `TarsPolicy.Meter` holds it, and what it cost is
  recorded there once it returns. A budget whose meter cannot be read refuses
  the call rather than letting it run unmetered; the host starts
  `TarsPolicy.Supervisor` to run the meters. Once the agent has spent its limit, a budget that
  asks parks it on the next call, and approving that call grants the budget's
  `grant` more for the period and lets it through. A budget that denies ends
  the turn instead.

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
  to message. `budget` takes what `TarsPolicy.Budget` describes.
  """

  @behaviour Tars.Policy
  @behaviour Tars.LLM.Dispatch

  require Logger

  alias Tars.LLM.Cost
  alias TarsPolicy.Budget
  alias TarsPolicy.Meter
  alias TarsPolicy.Pattern
  alias TarsPolicy.Rule
  alias TarsPolicy.Spend

  defstruct name: nil, rules: [], default: :allow, budget: nil

  @type t() :: %__MODULE__{
          name: String.t() | nil,
          rules: [Rule.t()],
          default: Rule.effect(),
          budget: Budget.t() | nil
        }

  @effects ~w(allow ask deny)
  @keys @effects ++ ["default", "budget"]
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

  # -- budgets ---------------------------------------------------------------

  @impl Tars.LLM.Dispatch
  def admit(request, _scope, %__MODULE__{budget: nil}), do: {:ok, request}

  def admit(request, scope, %__MODULE__{budget: budget}) do
    case scope |> spend_key(budget) |> Meter.read() do
      {:ok, spend} ->
        cond do
          not exhausted?(budget, spend) -> {:ok, request}
          budget.on_exhausted == :ask -> {:park, exhausted(budget, spend) <> " " <> more(budget)}
          true -> {:error, {:policy_denied, exhausted(budget, spend)}}
        end

      {:error, reason} ->
        {:error,
         {:policy_denied,
          "This agent's budget could not be read, so no call it governs may run: #{inspect(reason)}"}}
    end
  end

  @impl Tars.LLM.Dispatch
  def settle(request, {:ok, response}, scope, %__MODULE__{budget: %Budget{} = budget}) do
    usage = ReqLLM.Response.usage(response) || %{}
    micro_usd = Budget.micro(Cost.of(request.model_spec, usage) || 0)
    tokens = count(usage, :input_tokens) + count(usage, :output_tokens)

    with {:error, reason} <- scope |> spend_key(budget) |> Meter.spend(micro_usd, tokens) do
      Logger.error(
        "#{scope.source.agent_id} spent #{Budget.dollars(micro_usd)} and #{tokens} tokens that were not recorded: #{inspect(reason)}"
      )
    end

    :ok
  end

  def settle(_request, _outcome, _scope, _policy), do: :ok

  @impl Tars.LLM.Dispatch
  def approved(_request, scope, %__MODULE__{budget: %Budget{} = budget}) do
    {micro_usd, tokens} = Budget.grant(budget)

    with {:error, reason} <- scope |> spend_key(budget) |> Meter.grant(micro_usd, tokens) do
      Logger.error(
        "#{scope.source.agent_id} was granted more budget that was not recorded: #{inspect(reason)}"
      )
    end
  end

  def approved(_request, _scope, _policy), do: :ok

  @doc """
  What an agent has spent in its budget's period now, given the scope of one
  of its turns, or its key for a budget that is not per turn.
  """
  @spec spent(t(), Tars.Scope.t() | String.t()) :: Spend.t() | nil
  def spent(%__MODULE__{budget: nil}, _scope), do: nil
  def spent(%__MODULE__{budget: %Budget{per: :turn}}, agent) when is_binary(agent), do: nil

  def spent(%__MODULE__{budget: budget}, agent) when is_binary(agent),
    do: agent |> Spend.key(Budget.window(budget, "", DateTime.utc_now())) |> read()

  def spent(%__MODULE__{budget: budget}, scope), do: scope |> spend_key(budget) |> read()

  defp read(key) do
    case Meter.read(key) do
      {:ok, spend} -> spend
      {:error, _reason} -> nil
    end
  end

  @doc """
  What an agent has spent against its budget, as a phrase: `$1.20 of $5.00 and
  12000 of 200000 tokens today`.
  """
  @spec spending(t(), String.t()) :: String.t() | nil
  def spending(%__MODULE__{budget: budget} = policy, agent) do
    case spent(policy, agent) do
      nil -> nil
      %Spend{} = spend -> "#{amounts(budget, spend)} #{Budget.period_words(budget)}"
    end
  end

  defp spend_key(%Tars.Scope{source: source}, budget) do
    Spend.key(source.agent_id, Budget.window(budget, source.trace.trace_id, DateTime.utc_now()))
  end

  defp exhausted?(budget, spend) do
    (budget.usd != nil and spend.micro_usd >= Budget.micro_usd(budget) + spend.granted_micro_usd) or
      (budget.tokens != nil and spend.tokens >= budget.tokens + spend.granted_tokens)
  end

  defp exhausted(budget, spend),
    do: "This agent has spent #{amounts(budget, spend)} #{Budget.period_words(budget)}."

  defp amounts(budget, spend) do
    [
      budget.usd &&
        "#{Budget.dollars(spend.micro_usd)} of #{Budget.dollars(Budget.micro_usd(budget) + spend.granted_micro_usd)}",
      budget.tokens && "#{spend.tokens} of #{budget.tokens + spend.granted_tokens} tokens"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp more(budget) do
    {micro_usd, tokens} = Budget.grant(budget)

    granted =
      [budget.usd && Budget.dollars(micro_usd), budget.tokens && "#{tokens} tokens"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" and ")

    "Approve to allow #{granted} more."
  end

  defp count(usage, key) do
    case Map.get(usage, key) do
      n when is_integer(n) and n >= 0 -> n
      _missing -> 0
    end
  end

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
             {:ok, budget} <- budget(fields["budget"]) do
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

  defp budget(nil), do: {:ok, nil}
  defp budget(fields), do: Budget.decode(fields)

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
