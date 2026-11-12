defmodule WardrikDaemon.Ceiling do
  @moduledoc """
  A budget all of an org's agents share, from the org's policy. See `WardrikDaemon.Orgs`.

      # policies/plan.yaml, named by config.yaml's orgs.acme.policy
      budget: {usd: 20.00, per: month}

    * It counts what every agent of the org spends on models and tools, subagents included.
    * At the limit, the next model call does what `:on_exhausted` says. `:ask` (the default)
      waits for approval, which adds the budget's `grant` for the whole org. `:deny` refuses it.
    * A ceiling in dollars refuses models with no price.
    * Emits the telemetry event `[:wardrik_daemon, :ceiling, :reached]` when the limit is reached.
  """

  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context
  alias WardrikCore.Resume
  alias WardrikDaemon.Ceiling.Reached
  alias WardrikPolicy.Budget

  @enforce_keys [:name, :budget, :on_exhausted]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          name: String.t(),
          budget: Budget.t(),
          on_exhausted: :ask | :deny
        }

  @doc "Builds the ceiling `name` from a policy's budget. Returns an error for one per turn."
  @spec new(String.t(), Budget.t()) :: {:ok, t()} | {:error, String.t()}
  def new(name, %Budget{} = budget) do
    with :ok <- limited(budget),
         do: {:ok, %__MODULE__{name: name, budget: budget, on_exhausted: budget.on_exhausted}}
  end

  defp limited(%Budget{per: :turn}), do: {:error, "a ceiling isn't per turn"}
  defp limited(%Budget{usd: nil, tokens: nil}), do: {:error, "a ceiling sets usd, tokens or both"}
  defp limited(_budget), do: :ok

  @doc """
  Returns what `org`'s agents have spent against `ceiling` this period.

      %{
        limit: %{usd: 20.0, tokens: nil},
        spent: %{usd: 3.5, tokens: 120_000},
        granted: %{},
        on_exhausted: :ask,
        per: :day,
        starts_over: ~D[2026-10-31]
      }

  `:starts_over` is `nil` for `per: :total`.
  """
  @spec spent(WardrikStore.t(), String.t(), t()) :: map()
  def spent(store, org, %__MODULE__{budget: budget} = ceiling) do
    period = Budget.period(budget, DateTime.utc_now())
    {spent, _vsn} = current(WardrikStore.lookup(store, key(org, ceiling)), period)

    %{
      limit: %{usd: budget.usd, tokens: budget.tokens},
      spent: Map.take(spent, [:usd, :tokens]),
      granted: spent.granted,
      on_exhausted: ceiling.on_exhausted,
      per: budget.per,
      starts_over: starts_over(period)
    }
  end

  @doc "Returns `spent/3` as JSON, as `GET /v1/owners/{org}/ceilings` answers it."
  @spec json(WardrikStore.t(), String.t(), t()) :: map()
  def json(store, org, ceiling) do
    spend = spent(store, org, ceiling)

    %{
      "ceiling" => ceiling.name,
      "per" => Atom.to_string(spend.per),
      "on_exhausted" => Atom.to_string(spend.on_exhausted),
      "limit" => amount(spend.limit),
      "spent" => amount(spend.spent),
      "granted" => amount(spend.granted),
      "starts_over" => spend.starts_over && Date.to_iso8601(spend.starts_over)
    }
    |> Map.reject(fn {_key, value} -> value == nil end)
  end

  @doc """
  Returns each of `org`'s ceilings as `json/3` does, sorted by name.

  Returns `invalid_request` if `owner` is a user rather than an org.
  """
  @spec list(%{store: WardrikStore.t(), orgs: map()}, String.t()) ::
          {:ok, [map()]} | {:error, Wardrik.Error.t()}
  def list(%{store: store, orgs: orgs}, owner) do
    org = WardrikDaemon.Owners.org(owner)

    with :ok <- an_org(owner, org),
         {:ok, settings} <- WardrikDaemon.Orgs.settings(org, orgs) do
      {:ok, settings.ceilings |> Enum.map(&json(store, org, &1)) |> Enum.sort_by(& &1["ceiling"])}
    end
  end

  defp an_org(org, org), do: :ok

  defp an_org(_owner, org),
    do:
      {:error,
       Wardrik.Error.new(:invalid_request, "Ceilings belong to orgs. Ask for #{org}'s ceilings.")}

  defp amount(amount),
    do: for({kind, value} <- amount, value != nil, into: %{}, do: {Atom.to_string(kind), value})

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
    decisions =
      for ceiling <- held.ceilings,
          do: decision(held.org, ceiling, read(held.store, held.org, ceiling))

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
    for %__MODULE__{on_exhausted: :ask} = ceiling <- held.ceilings,
        do: update(held.store, held.org, ceiling, &granted(ceiling, &1))

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
    for ceiling <- held.ceilings do
      {spent, now} = update(held.store, held.org, ceiling, &spend(ceiling.budget, &1, gained))
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

  # Telemetry only: Wardrik's event log holds Wardrik's events, and ceilings are the daemon's.
  defp emit_reached(context, org, ceiling, message) do
    :telemetry.execute([:wardrik_daemon, :ceiling, :reached], %{}, %{
      agent_id: context.agent_id,
      conversation: context.conversation,
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

  defp read(store, org, ceiling) do
    period = Budget.period(ceiling.budget, DateTime.utc_now())
    {spent, _vsn} = current(WardrikStore.lookup(store, key(org, ceiling)), period)
    spent
  end

  defp update(store, org, ceiling, change) do
    key = key(org, ceiling)
    period = Budget.period(ceiling.budget, DateTime.utc_now())
    {spent, vsn} = current(WardrikStore.lookup(store, key), period)
    changed = change.(spent)

    case WardrikStore.put(store, key, stored(changed, period), if_vsn: vsn) do
      {:ok, _vsn} -> {spent, changed}
      {:error, :conflict} -> update(store, org, ceiling, change)
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
end
