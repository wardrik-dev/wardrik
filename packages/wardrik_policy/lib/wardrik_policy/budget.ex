defmodule WardrikPolicy.Budget do
  @moduledoc """
  How much an agent may spend on model calls, over what period, and what
  happens once it has.

      budget:
        usd: 5.00
        tokens: 200000
        per: day
        on_exhausted: ask

  | Field | What it decides |
  | --- | --- |
  | `usd` | a limit in US dollars, as `Wardrik.LLM.Cost` prices each call |
  | `tokens` | a limit in tokens, input and output together |
  | `per` | the period the limits cover: `turn`, `day`, `week`, `month`, or `total` for the agent's whole life. `day` unless set |
  | `grant` | how much more a person's approval allows, as `usd` and `tokens`. Another of each limit unless set |
  | `on_exhausted` | `ask`, which parks the agent until a person approves more, or `deny`, which ends the turn. `ask` unless set |

  A budget sets `usd`, `tokens`, or both, and is spent when either is. A token
  limit governs a model the catalog cannot price, or one a subscription pays
  for, whose calls cost nothing in dollars; a budget in dollars refuses a model
  the catalog cannot price.

  Days, weeks and months are UTC calendar periods, and a week starts on
  Monday. A turn's budget covers the model calls of that turn and every
  delegation under it.

  The limits are checked before each call, against what the calls before it
  spent, so the call that crosses one runs and the next is stopped. Calls
  admitted side by side, as delegations running at once are, can each cross
  it.

  ## As a hook

  A budget is a `Wardrik.Hook`, as `WardrikPolicy.hooks/1` names it. Each model
  call is checked before it is made against what the agent has spent in the
  budget's period, as its `WardrikPolicy.Meter` holds it, and what it used is
  recorded there once it returns. A budget whose meter cannot be read refuses
  the call rather than letting it run unmetered; the host starts
  `WardrikPolicy.Supervisor` to run the meters. Once the agent has spent its
  limit, a budget that asks parks it on the next call, and approving that
  call grants the budget's `grant` more for the period the call was asked
  in. A budget that denies ends the turn instead. A budget in dollars refuses
  every call to a model the catalog cannot price.
  """

  @behaviour Wardrik.Hook

  require Logger

  alias Wardrik.Call
  alias Wardrik.LLM.Cost
  alias Wardrik.LLM.Usage
  alias WardrikPolicy.Meter
  alias WardrikPolicy.Spend

  @unpriced "This agent's budget is in dollars, and the catalog has no price for its model, so " <>
              "what its calls cost cannot be counted. A budget in tokens alone can count them."

  defstruct [:usd, :tokens, :grant_usd, :grant_tokens, per: :day, on_exhausted: :ask]

  @typedoc "The period a budget covers."
  @type period() :: :turn | :day | :week | :month | :total

  @type t() :: %__MODULE__{
          usd: float() | nil,
          tokens: pos_integer() | nil,
          grant_usd: float() | nil,
          grant_tokens: pos_integer() | nil,
          per: period(),
          on_exhausted: :ask | :deny
        }

  @keys ~w(usd tokens per grant on_exhausted)
  @periods %{
    "turn" => :turn,
    "day" => :day,
    "week" => :week,
    "month" => :month,
    "total" => :total
  }

  @doc "The budget a map with string keys writes."
  @spec decode(term()) :: {:ok, t()} | {:error, String.t()}
  def decode(%{} = fields) do
    with [] <- Map.keys(fields) -- @keys,
         {:ok, usd} <- optional(fields["usd"], &dollars(&1, "usd")),
         {:ok, tokens} <- optional(fields["tokens"], &tokens(&1, "tokens")),
         :ok <- some_limit(usd, tokens),
         {:ok, grant_usd, grant_tokens} <- read_grant(fields["grant"]),
         {:ok, per} <- period(Map.get(fields, "per", "day")),
         {:ok, on_exhausted} <- exhausted(Map.get(fields, "on_exhausted", "ask")) do
      {:ok,
       %__MODULE__{
         usd: usd,
         tokens: tokens,
         grant_usd: grant_usd,
         grant_tokens: grant_tokens,
         per: per,
         on_exhausted: on_exhausted
       }}
    else
      [key | _] ->
        {:error, "budget #{key} is not a setting; expected one of #{Enum.join(@keys, ", ")}"}

      {:error, message} ->
        {:error, "budget " <> message}
    end
  end

  def decode(_fields),
    do: {:error, "budget is a set of settings: usd, tokens, per, grant and on_exhausted"}

  @doc "The map `decode/1` reads `budget` back from."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = budget) do
    grant = drop_nil(%{"usd" => budget.grant_usd, "tokens" => budget.grant_tokens})

    %{
      "usd" => budget.usd,
      "tokens" => budget.tokens,
      "per" => Atom.to_string(budget.per),
      "on_exhausted" => Atom.to_string(budget.on_exhausted),
      "grant" => if(grant == %{}, do: nil, else: grant)
    }
    |> drop_nil()
  end

  # -- as a hook ---------------------------------------------------------------

  @impl Wardrik.Hook
  def init(%__MODULE__{} = budget), do: budget

  def init(%{} = fields) do
    case decode(fields) do
      {:ok, budget} -> budget
      {:error, message} -> raise ArgumentError, message
    end
  end

  @impl Wardrik.Hook
  def call(%Call{target: %Call.Model{model_spec: spec}} = call, %__MODULE__{} = budget) do
    if budget.usd != nil and not Cost.priced?(spec),
      do: Call.deny(call, @unpriced),
      else: metered(call, spend_key(call.scope, budget), budget)
  end

  def call(%Call{} = call, %__MODULE__{}), do: call

  # The memo an ask carries is the meter it read, so an approval grants more
  # to the period that ran out.
  defp metered(call, key, budget) do
    case Meter.read(key) do
      {:ok, spend} ->
        cond do
          not exhausted?(budget, spend) ->
            call

          budget.on_exhausted == :ask ->
            Call.ask(call, exhausted(budget, spend) <> " " <> more(budget), key)

          true ->
            Call.deny(call, exhausted(budget, spend))
        end

      {:error, reason} ->
        Call.deny(
          call,
          "This agent's budget could not be read, so no call it governs may run: #{inspect(reason)}"
        )
    end
  end

  @impl Wardrik.Hook
  def approved(%Call{target: %Call.Model{}, scope: scope} = call, %__MODULE__{} = budget) do
    {micro_usd, tokens} = grant(budget)

    with key when is_binary(key) <- Call.memo(call),
         {:error, reason} <- Meter.grant(key, micro_usd, tokens) do
      Logger.error(
        "#{scope.source.agent_id} was granted more budget that was not recorded: #{inspect(reason)}"
      )
    end
  end

  def approved(%Call{}, %__MODULE__{}), do: :ok

  @impl Wardrik.Hook
  def settle(%Call{target: %Call.Model{} = model, scope: scope}, %__MODULE__{} = budget) do
    usage = model.usage
    micro_usd = micro(Cost.of(model.model_spec, usage) || 0)
    tokens = Usage.tokens(usage)

    with {:error, reason} <- scope |> spend_key(budget) |> Meter.spend(micro_usd, tokens) do
      Logger.error(
        "#{scope.source.agent_id} spent #{dollars(micro_usd)} and #{tokens} tokens that were not recorded: #{inspect(reason)}"
      )
    end

    :ok
  end

  @doc """
  What an agent has spent in `budget`'s period now, given the scope of one of
  its turns, or its key for a budget that is not per turn.
  """
  @spec spent(t(), Wardrik.Scope.t() | String.t()) :: Spend.t() | nil
  def spent(%__MODULE__{per: :turn}, agent) when is_binary(agent), do: nil

  def spent(%__MODULE__{} = budget, agent) when is_binary(agent),
    do: agent |> Spend.key(window(budget, "", DateTime.utc_now())) |> read()

  def spent(%__MODULE__{} = budget, scope), do: scope |> spend_key(budget) |> read()

  defp read(key) do
    case Meter.read(key) do
      {:ok, spend} -> spend
      {:error, _reason} -> nil
    end
  end

  @doc """
  What an agent has spent against `budget`, as a phrase: `$1.20 of $5.00 and
  12000 of 200000 tokens today`.
  """
  @spec spending(t(), String.t()) :: String.t() | nil
  def spending(%__MODULE__{} = budget, agent) do
    case spent(budget, agent) do
      nil -> nil
      %Spend{} = spend -> "#{amounts(budget, spend)} #{period_words(budget)}"
    end
  end

  defp spend_key(%Wardrik.Scope{source: source}, budget) do
    Spend.key(source.agent_id, window(budget, source.trace.trace_id, DateTime.utc_now()))
  end

  defp exhausted?(budget, spend) do
    (budget.usd != nil and spend.micro_usd >= micro_usd(budget) + spend.granted_micro_usd) or
      (budget.tokens != nil and spend.tokens >= budget.tokens + spend.granted_tokens)
  end

  defp exhausted(budget, spend),
    do: "This agent has spent #{amounts(budget, spend)} #{period_words(budget)}."

  defp amounts(budget, spend) do
    [
      budget.usd &&
        "#{dollars(spend.micro_usd)} of #{dollars(micro_usd(budget) + spend.granted_micro_usd)}",
      budget.tokens && "#{spend.tokens} of #{budget.tokens + spend.granted_tokens} tokens"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp more(budget) do
    {micro_usd, tokens} = grant(budget)

    granted =
      [budget.usd && dollars(micro_usd), budget.tokens && "#{tokens} tokens"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" and ")

    "Approve to allow #{granted} more."
  end

  # -- amounts -----------------------------------------------------------------

  @doc """
  How much more a person's approval allows, as `{micro_usd, tokens}`, each `0`
  where the budget sets no such limit.
  """
  @spec grant(t()) :: {non_neg_integer(), non_neg_integer()}
  def grant(%__MODULE__{} = budget) do
    {micro(budget.grant_usd || budget.usd || 0), budget.grant_tokens || budget.tokens || 0}
  end

  @doc "The dollar limit in whole micro-dollars, or `nil` where the budget sets none."
  @spec micro_usd(t()) :: non_neg_integer() | nil
  def micro_usd(%__MODULE__{usd: nil}), do: nil
  def micro_usd(%__MODULE__{usd: usd}), do: micro(usd)

  @doc "`usd` dollars in whole micro-dollars, rounded to the nearest."
  @spec micro(number()) :: non_neg_integer()
  def micro(usd), do: round(usd * 1_000_000)

  @doc "Whole micro-dollars as dollars and cents: `$1.20`."
  @spec dollars(non_neg_integer()) :: String.t()
  def dollars(micro_usd), do: "$" <> :erlang.float_to_binary(micro_usd / 1_000_000, decimals: 2)

  @doc """
  The name of the period `now` falls in, for a turn traced as `trace_id`:
  `day:2026-09-23`, `week:2026-W39`, `month:2026-09`, `turn:<trace>` or `total`.
  """
  @spec window(t(), String.t(), DateTime.t()) :: String.t()
  def window(%__MODULE__{per: :turn}, trace_id, _now), do: "turn:" <> trace_id
  def window(%__MODULE__{per: :total}, _trace_id, _now), do: "total"

  def window(%__MODULE__{per: :day}, _trace_id, now),
    do: "day:" <> Date.to_iso8601(DateTime.to_date(now))

  def window(%__MODULE__{per: :week}, _trace_id, now) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(DateTime.to_date(now)))
    "week:#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  def window(%__MODULE__{per: :month}, _trace_id, now),
    do: "month:#{now.year}-#{String.pad_leading(Integer.to_string(now.month), 2, "0")}"

  @doc "How the period reads in a sentence: `today`, `this week`, `this turn`."
  @spec period_words(t()) :: String.t()
  def period_words(%__MODULE__{per: :turn}), do: "this turn"
  def period_words(%__MODULE__{per: :day}), do: "today"
  def period_words(%__MODULE__{per: :week}), do: "this week"
  def period_words(%__MODULE__{per: :month}), do: "this month"
  def period_words(%__MODULE__{per: :total}), do: "in total"

  defp dollars(n, _key) when is_number(n) and n > 0, do: {:ok, n / 1}
  defp dollars(_n, key), do: {:error, "#{key} is a number of dollars above zero"}

  defp tokens(n, _key) when is_integer(n) and n > 0, do: {:ok, n}
  defp tokens(_n, key), do: {:error, "#{key} is a whole number of tokens above zero"}

  defp optional(nil, _read), do: {:ok, nil}
  defp optional(value, read), do: read.(value)

  defp some_limit(nil, nil), do: {:error, "sets usd, tokens, or both"}
  defp some_limit(_usd, _tokens), do: :ok

  defp read_grant(nil), do: {:ok, nil, nil}

  defp read_grant(%{} = grant) do
    with [] <- Map.keys(grant) -- ["usd", "tokens"],
         {:ok, usd} <- optional(grant["usd"], &dollars(&1, "grant usd")),
         {:ok, tokens} <- optional(grant["tokens"], &tokens(&1, "grant tokens")) do
      {:ok, usd, tokens}
    else
      [key | _] -> {:error, "grant #{key} is not a setting; expected usd or tokens"}
      error -> error
    end
  end

  defp read_grant(_grant), do: {:error, "grant is usd, tokens, or both"}

  defp drop_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp period(value) do
    case Map.fetch(@periods, value) do
      {:ok, period} -> {:ok, period}
      :error -> {:error, "per is turn, day, week, month or total"}
    end
  end

  defp exhausted("ask"), do: {:ok, :ask}
  defp exhausted("deny"), do: {:ok, :deny}
  defp exhausted(_value), do: {:error, "on_exhausted is ask or deny"}
end
