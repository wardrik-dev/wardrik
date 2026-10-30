defmodule Wardrik.Ceiling do
  @moduledoc """
  A budget all of an org's agents share. Set ceilings in the org's `Wardrik.OrgSettings`:

      ceilings: %{
        "spending-cap" => [usd: 20.00, per: :day],
        "free-allowance" => [usd: 5.00, per: :total, on_exhausted: :deny],
        "watch" => [tokens: 2_000_000, per: :month, on_exhausted: :continue]
      }

  A ceiling takes the same settings as `WardrikPolicy.Budget`, except `per: :turn`. It must set
  `:usd`, `:tokens` or both. Wardrik counts what the org's model and tool calls spend in each
  period.

  Once the limit is reached, the next model call by any of the org's agents does what
  `:on_exhausted` says:

    * `:ask` - the default. The call waits on a `ceiling_approval` interrupt. Only a scope allowed
      `ceiling.approve` on the org's ceiling resource, such as `acme/ceiling`, may approve it.
      Owners can. Approving adds the budget's `grant` for every agent in the org, for that period.
    * `:deny` - the call is refused.
    * `:continue` - the call runs.

  Every ceiling emits `[:wardrik, :ceiling, :reached]` when its limit is reached.

  A ceiling in dollars refuses models with no price, unless it's `:continue`. Subagents' model
  calls count too, as part of the tool call that ran them.
  """

  @behaviour WardrikCore.Middleware

  alias Wardrik.Ceiling.Reached
  alias WardrikCore.Context
  alias WardrikCore.Resume
  alias WardrikPolicy.Budget

  @enforce_keys [:name, :budget, :on_exhausted]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          name: String.t(),
          budget: Budget.t(),
          on_exhausted: :ask | :deny | :continue
        }

  @modes %{"ask" => :ask, "deny" => :deny, "continue" => :continue}

  @doc "Builds the ceiling `name` from budget settings, as a keyword list or a string-keyed map."
  @spec new(String.t(), keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(name, settings) when is_list(settings) do
    {mode, settings} = Keyword.pop(settings, :on_exhausted, :ask)
    built(name, mode, fn -> {:ok, struct!(Budget, [on_exhausted: :deny] ++ settings)} end)
  rescue
    error in [ArgumentError, KeyError] -> {:error, Exception.message(error)}
  end

  def new(name, settings) when is_map(settings) do
    {mode, settings} = Map.pop(settings, "on_exhausted", "ask")
    built(name, @modes[mode], fn -> Budget.decode(Map.put(settings, "on_exhausted", "deny")) end)
  end

  def new(_name, _settings), do: {:error, "a ceiling is a budget's settings"}

  defp built(name, mode, budget) when mode in [:ask, :deny, :continue] do
    with {:ok, budget} <- budget.(),
         :ok <- limited(budget),
         do: {:ok, %__MODULE__{name: name, budget: stopping(budget, mode), on_exhausted: mode}}
  end

  defp built(_name, _mode, _budget), do: {:error, "on_exhausted is ask, deny or continue"}

  defp limited(%Budget{per: :turn}), do: {:error, "a ceiling isn't per turn"}
  defp limited(%Budget{usd: nil, tokens: nil}), do: {:error, "a ceiling sets usd, tokens or both"}
  defp limited(_budget), do: :ok

  defp stopping(budget, :ask), do: %{budget | on_exhausted: :ask}
  defp stopping(budget, _mode), do: budget

  @doc """
  Returns what `org`'s agents have spent against `ceiling` in the current period.

      %{
        limit: %{usd: 20.0, tokens: nil},
        spent: %{usd: 3.5, tokens: 120_000},
        granted: %{},
        on_exhausted: :ask,
        per: :day,
        starts_over: ~D[2026-10-31]
      }

  `:starts_over` is `nil` for a `per: :total` ceiling.
  """
  @spec spent(Wardrik.t(), String.t(), t()) :: map()
  def spent(wardrik, org, %__MODULE__{budget: budget} = ceiling) do
    period = Budget.period(budget, DateTime.utc_now())
    {spent, _vsn} = current(WardrikStore.lookup(store(wardrik), key(org, ceiling)), period)

    %{
      limit: %{usd: budget.usd, tokens: budget.tokens},
      spent: Map.take(spent, [:usd, :tokens]),
      granted: spent.granted,
      on_exhausted: ceiling.on_exhausted,
      per: budget.per,
      starts_over: starts_over(period)
    }
  end

  @impl WardrikCore.Middleware
  def call(%Context{step: :generate} = context, next, held) do
    case stopped(held) do
      nil -> counted(context, next, held)
      {:deny, message} -> {:error, message}
      {:ask, message} -> asked(context, next, held, message)
    end
  end

  def call(%Context{step: {:tool_call, _call}} = context, next, held),
    do: counted(context, next, held)

  def call(context, next, _held), do: next.(context)

  defp stopped(held) do
    wardrik = Wardrik.Instance.fetch!(held.wardrik)

    decisions =
      for %__MODULE__{on_exhausted: mode} = ceiling <- held.ceilings,
          mode != :continue,
          do: decision(held.org, ceiling, read(wardrik, held.org, ceiling))

    Enum.find(decisions, &match?({:deny, _message}, &1)) ||
      Enum.find(decisions, &match?({:ask, _message}, &1))
  end

  defp decision(org, %__MODULE__{budget: %Budget{usd: usd, price: nil}}, %{unpriced: true})
       when usd != nil,
       do: {:deny, "This model has no price in dollars, so #{org}'s ceiling can't hold it."}

  defp decision(org, ceiling, spent),
    do: Budget.check(ceiling.budget, spent, spender: "#{org}'s agents have")

  defp asked(context, next, held, message) do
    case answer(context) do
      nil ->
        {:park, %Reached{message: message, labels: Context.labels(context)}, context}

      answer ->
        resolved(context, answer)
        answered(answer, context, next, held)
    end
  end

  defp answer(%Context{resume: %Resume{reason: %Reached{}, input: input}}) when is_map(input),
    do: Map.get(input, "model")

  defp answer(_context), do: nil

  defp answered({:deny, reason}, _context, _next, _held), do: {:error, reason}

  defp answered(_approved, context, next, held) do
    wardrik = Wardrik.Instance.fetch!(held.wardrik)

    for %__MODULE__{on_exhausted: :ask} = ceiling <- held.ceilings,
        do: update(wardrik, held.org, ceiling, &granted(ceiling, &1))

    counted(context, next, held)
  end

  defp granted(ceiling, spent) do
    case Budget.check(ceiling.budget, spent) do
      :allow -> spent
      _exhausted -> Budget.grant(ceiling.budget, spent)
    end
  end

  defp counted(%Context{subagent: name} = context, next, _held) when is_binary(name),
    do: next.(context)

  defp counted(context, next, held) do
    case next.(context) do
      {:ok, after_step} = done ->
        recorded(context, held, gained(context.measurements, after_step.measurements))
        done

      other ->
        other
    end
  end

  defp gained(before, measured) do
    [:input_tokens, :output_tokens, :usd, :unpriced_calls]
    |> Map.new(&{&1, Map.get(measured, &1, 0) - Map.get(before, &1, 0)})
    |> Map.reject(fn {_key, amount} -> amount == 0 end)
  end

  defp recorded(_context, _held, gained) when map_size(gained) == 0, do: :ok

  defp recorded(context, held, gained) do
    wardrik = Wardrik.Instance.fetch!(held.wardrik)

    for ceiling <- held.ceilings do
      {spent, now} = update(wardrik, held.org, ceiling, &spend(ceiling.budget, &1, gained))
      reached(context, held.org, ceiling, decision(held.org, ceiling, spent), now)
    end

    :ok
  end

  defp spend(budget, spent, gained) do
    cost = cost(budget, gained)
    tokens = Map.get(gained, :input_tokens, 0) + Map.get(gained, :output_tokens, 0)

    %{
      spent
      | usd: spent.usd + (cost || 0),
        tokens: spent.tokens + tokens,
        unpriced: spent.unpriced or cost == nil
    }
  end

  defp cost(budget, %{unpriced_calls: _calls} = gained),
    do: Budget.cost(budget, Map.delete(gained, :usd))

  defp cost(_budget, gained), do: Map.get(gained, :usd, 0)

  defp reached(context, org, ceiling, :allow, now) do
    case decision(org, ceiling, now) do
      :allow -> :ok
      {_effect, message} -> emit_reached(context, org, ceiling, message)
    end
  end

  defp reached(_context, _org, _ceiling, _before, _now), do: :ok

  defp emit_reached(context, org, ceiling, message) do
    WardrikCore.Event.emit(context, [:wardrik, :ceiling, :reached], %{}, %{
      agent_id: context.agent_id,
      span: context.span,
      org: org,
      ceiling: ceiling.name,
      on_exhausted: ceiling.on_exhausted,
      message: message
    })
  end

  defp resolved(context, answer) do
    WardrikCore.Event.emit(
      context,
      [:wardrik, :interrupt, :resolved],
      %{},
      Map.merge(
        %{agent_id: context.agent_id, span: context.span, interrupt: %{id: "model"}},
        resolution(answer, context.resume.metadata)
      )
    )
  end

  defp resolution({:deny, reason}, metadata),
    do: by(%{decision: "rejected", reason: reason}, metadata)

  defp resolution({:approve, note}, metadata),
    do: by(%{decision: "approved", note: note}, metadata)

  defp resolution(:approve, metadata), do: by(%{decision: "approved"}, metadata)

  defp by(resolution, %{by: by}) when by != nil, do: Map.put(resolution, :resolved_by, by)
  defp by(resolution, _metadata), do: resolution

  defp read(wardrik, org, ceiling) do
    period = Budget.period(ceiling.budget, DateTime.utc_now())
    {spent, _vsn} = current(WardrikStore.lookup(store(wardrik), key(org, ceiling)), period)
    spent
  end

  defp update(wardrik, org, ceiling, change) do
    store = store(wardrik)
    key = key(org, ceiling)
    period = Budget.period(ceiling.budget, DateTime.utc_now())
    {spent, vsn} = current(WardrikStore.lookup(store, key), period)
    changed = change.(spent)

    case WardrikStore.put(store, key, stored(changed, period), if_vsn: vsn) do
      {:ok, _vsn} -> {spent, changed}
      {:error, :conflict} -> update(wardrik, org, ceiling, change)
    end
  end

  defp current({%{"period" => written} = spent, vsn}, period) do
    if written == period_name(period), do: {loaded(spent), vsn}, else: {fresh(), vsn}
  end

  defp current(nil, _period), do: {fresh(), nil}

  defp fresh, do: %{usd: 0, tokens: 0, granted: %{}, unpriced: false}

  defp loaded(spent) do
    %{
      usd: spent["usd"],
      tokens: spent["tokens"],
      granted: Map.new(spent["granted"], fn {kind, amount} -> {kind(kind), amount} end),
      unpriced: spent["unpriced"]
    }
  end

  defp stored(spent, period) do
    %{
      "period" => period_name(period),
      "usd" => spent.usd,
      "tokens" => spent.tokens,
      "granted" => Map.new(spent.granted, fn {kind, amount} -> {to_string(kind), amount} end),
      "unpriced" => spent.unpriced
    }
  end

  defp kind("usd"), do: :usd
  defp kind("tokens"), do: :tokens

  defp period_name(:total), do: "total"
  defp period_name({per, date}), do: "#{per}/#{Date.to_iso8601(date)}"

  defp starts_over(:total), do: nil
  defp starts_over({:day, date}), do: Date.add(date, 1)
  defp starts_over({:week, date}), do: Date.add(date, 7)
  defp starts_over({:month, date}), do: Date.shift(date, month: 1)

  defp key(org, ceiling), do: "ceilings/#{org}/#{ceiling.name}"
  defp store(%Wardrik{store: store}), do: WardrikStore.scope(store, "wardrik")
end
