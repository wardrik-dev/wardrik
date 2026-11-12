defmodule WardrikGateway do
  @moduledoc """
  Rate limits, circuit breakers and model failover for agents' model calls.

  Application integration fragment. Start the required processes before calling these functions.
  See the [package README](https://github.com/wardrik-dev/wardrik/tree/main/extensions/wardrik_gateway#readme) for complete setup.

      children = [
        {WardrikGateway,
         name: MyApp.Gateway,
         fallbacks: %{"anthropic:claude-sonnet-4-5" => ["openai:gpt-5", "zai:glm-5.1"]},
         limits: %{"anthropic" => [requests_per_minute: 4000, tokens_per_minute: 400_000]}},
        {MyApp.AgentRuntime, middleware: [{WardrikGateway, MyApp.Gateway}]}
      ]

  With `WardrikCore` alone, pass the same entry in an agent's `:middleware`.

    * A model with an open breaker is skipped. The call goes to the next model in `fallbacks`.
    * A call to a provider at its limit is delayed until the provider has capacity.
    * A 429 delays calls to that provider for its `Retry-After`, or one second.
    * A 5xx, a 529 or a timeout counts towards the model's breaker. The call goes to the next
      model.
    * After a fallback, the rest of the turn uses the fallback.
    * A call is delayed at most `:wait`. Then `WardrikCore.Retry` applies.

  ## Options

  #{NimbleOptions.docs(NimbleOptions.new!(name: [type: :atom, required: true, doc: "The gateway's name."]))}
  #{NimbleOptions.docs(WardrikGateway.Settings.schema())}

  ## Telemetry

    * `[:wardrik_gateway, :failover]` - `from`, `to`, `reason` and `agent_id`.
    * `[:wardrik_gateway, :limited]` - measures `wait`, in milliseconds, with `model` and
      `agent_id`.
    * `[:wardrik_gateway, :breaker_opened]` and `[:wardrik_gateway, :breaker_closed]` - `model`.
  """

  use GenServer

  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context
  alias WardrikGateway.Settings
  alias WardrikGateway.State

  @doc "Starts a gateway registered as `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, Settings.new!(opts), name: name)
  end

  @doc "Returns the schema of the settings `start_link/1` and `configure/2` take, but `:name`."
  @spec schema() :: NimbleOptions.t()
  def schema, do: Settings.schema()

  @doc """
  Replaces the settings at runtime. Breaker and limit counts are kept.

      WardrikGateway.configure(MyApp.Gateway, limits: %{"anthropic" => [requests_per_minute: 2000]})
  """
  @spec configure(GenServer.server(), keyword()) :: :ok
  def configure(gateway, opts), do: GenServer.call(gateway, {:configure, Settings.new!(opts)})

  @impl WardrikCore.Middleware
  def call(%Context{step: :generate} = context, next, gateway) do
    {models, wait} = GenServer.call(gateway, {:plan, context.model})
    tried(context, next, gateway, models, now() + wait, nil)
  end

  def call(context, next, _gateway), do: next.(context)

  defp tried(context, next, gateway, models, deadline, failed) do
    remaining = max(deadline - now(), 0)

    case GenServer.call(gateway, {:admit, models, remaining}) do
      {:go, model, wait} ->
        held(context, model, wait)
        result = next.(%{context | model: model})

        answered(
          result,
          %{context: context, next: next, gateway: gateway},
          models,
          deadline,
          model
        )

      {:wait, wait} when is_integer(wait) and wait <= remaining ->
        Process.sleep(wait)
        tried(context, next, gateway, models, deadline, failed)

      {:wait, _wait} ->
        {:error, failed || %WardrikGateway.Unavailable{models: models}}
    end
  end

  defp held(_context, _model, 0), do: :ok

  defp held(context, model, wait) do
    :telemetry.execute([:wardrik_gateway, :limited], %{wait: wait}, %{
      model: model,
      agent_id: context.agent_id
    })

    Process.sleep(wait)
  end

  defp answered({:ok, context} = answer, call, _models, _deadline, model) do
    report(call.gateway, model, {:ok, tokens(context.response)})
    answer
  end

  defp answered({:error, reason} = error, call, models, deadline, model) do
    outcome = outcome(reason)
    report(call.gateway, model, outcome)

    case {outcome, after_model(models, model)} do
      {:hopeless, _rest} ->
        error

      {_outcome, []} ->
        error

      {_outcome, [next_model | _more] = rest} ->
        failover(call, rest, deadline, reason, model, next_model)
    end
  end

  defp answered(parked, _call, _models, _deadline, _model), do: parked

  defp failover(call, rest, deadline, reason, model, next_model) do
    :telemetry.execute([:wardrik_gateway, :failover], %{}, %{
      from: model,
      to: next_model,
      reason: reason,
      agent_id: call.context.agent_id
    })

    tried(call.context, call.next, call.gateway, rest, deadline, reason)
  end

  defp after_model(models, model), do: models |> Enum.drop_while(&(&1 != model)) |> tl()

  defp outcome(%{status: 429} = reason), do: {:limited, retry_after(reason)}
  defp outcome(reason), do: if(WardrikCore.Retry.transient?(reason), do: :failed, else: :hopeless)

  # Mint gives headers as a list of pairs, Req as a map of lists. A second unless they say.
  defp retry_after(%{headers: headers}) when is_list(headers) or is_map(headers) do
    Enum.find_value(headers, :timer.seconds(1), fn
      {"retry-after", [value | _rest]} -> seconds(value)
      {"retry-after", value} when is_binary(value) -> seconds(value)
      _header -> nil
    end)
  end

  defp retry_after(_reason), do: :timer.seconds(1)

  defp seconds(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> :timer.seconds(seconds)
      _date -> nil
    end
  end

  defp tokens(%ReqLLM.Response{} = response) do
    usage = ReqLLM.Response.usage(response) || %{}
    Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
  end

  defp tokens(_response), do: 0

  defp report(gateway, model, outcome), do: GenServer.cast(gateway, {:report, model, outcome})

  defp now, do: System.monotonic_time(:millisecond)

  @impl GenServer
  def init(settings), do: {:ok, State.new(settings)}

  @impl GenServer
  def handle_call({:plan, model}, _from, state), do: {:reply, State.plan(state, model), state}

  def handle_call({:admit, models, remaining}, _from, state) do
    {reply, state} = State.admit(state, models, remaining, now())
    {:reply, reply, state}
  end

  def handle_call({:configure, settings}, _from, state),
    do: {:reply, :ok, State.configure(state, settings)}

  @impl GenServer
  def handle_cast({:report, model, outcome}, state) do
    {events, state} = State.report(state, model, outcome, now())
    for {event, metadata} <- events, do: :telemetry.execute(event, %{}, metadata)
    {:noreply, state}
  end
end
