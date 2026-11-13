defmodule Wardrik.Spending do
  @moduledoc false

  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context

  @impl WardrikCore.Middleware
  def call(%Context{subagent: name} = context, next, _instance) when is_binary(name),
    do: next.(context)

  def call(%Context{step: :generate} = context, next, instance),
    do: counted(context, next, instance)

  def call(%Context{step: {:tool_call, _call}} = context, next, instance),
    do: counted(context, next, instance)

  def call(context, next, _instance), do: next.(context)

  defp counted(context, next, instance) do
    case next.(context) do
      {:ok, after_step} = done ->
        spent(instance, context.agent_id, gained(context.measurements, after_step.measurements))
        done

      other ->
        other
    end
  end

  @doc """
  Returns what the agent `id` spent today.

      Wardrik.Spending.today(wardrik, "agt_triage")
      #=> %{"tokens" => 12_400, "usd" => 0.03}
  """
  @spec today(Wardrik.t(), String.t()) :: %{String.t() => number()}
  def today(wardrik, id) do
    wardrik
    |> by_agent([id])
    |> Map.fetch!(id)
  end

  @doc "Returns what each of `ids` spent today, by ID, in one read."
  @spec by_agent(Wardrik.t(), [String.t()]) :: %{String.t() => %{String.t() => number()}}
  def by_agent(wardrik, ids) do
    today = today()
    store = store(wardrik)
    found = Wardrik.Store.lookup_many(store, Enum.map(ids, &key/1))

    Map.new(ids, fn id ->
      case found[key(id)] do
        {%{"day" => ^today} = spent, _vsn} -> {id, Map.take(spent, ["tokens", "usd"])}
        _none -> {id, %{"tokens" => 0, "usd" => 0}}
      end
    end)
  end

  defp gained(before, measured) do
    Map.new([:input_tokens, :output_tokens, :usd], fn key ->
      {key, Map.get(measured, key, 0) - Map.get(before, key, 0)}
    end)
  end

  defp spent(_instance, _id, %{input_tokens: 0, output_tokens: 0, usd: 0}), do: :ok

  defp spent(instance, id, gained) do
    wardrik = Wardrik.Instance.fetch!(instance)
    tokens = gained.input_tokens + gained.output_tokens
    add(store(wardrik), key(id), tokens, gained.usd)
  end

  defp add(store, key, tokens, usd) do
    {spent, vsn} = current(Wardrik.Store.lookup(store, key))
    added = %{spent | "tokens" => spent["tokens"] + tokens, "usd" => spent["usd"] + usd}

    case Wardrik.Store.put(store, key, added, if_vsn: vsn) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> add(store, key, tokens, usd)
    end
  end

  defp current({%{"day" => day} = spent, vsn}) do
    if day == today(), do: {spent, vsn}, else: {fresh(), vsn}
  end

  defp current(nil), do: {fresh(), nil}

  defp fresh, do: %{"day" => today(), "tokens" => 0, "usd" => 0}

  defp today, do: Date.to_iso8601(Date.utc_today())

  defp key(id), do: "spending/" <> id
  defp store(%Wardrik{store: store}), do: Wardrik.Store.scope(store, "wardrik")
end
