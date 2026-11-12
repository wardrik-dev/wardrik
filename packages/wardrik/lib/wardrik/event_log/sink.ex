defmodule Wardrik.EventLog.Sink do
  @moduledoc """
  A behaviour for sending events on, to a warehouse, a queue or tracing.

      defmodule MyApp.Shipper do
        @behaviour Wardrik.EventLog.Sink

        @impl true
        def handle_event(event, opts), do: MyApp.Queue.push(opts[:queue], event)
      end

      {Wardrik.EventLog, name: MyApp.Events, store: store, sinks: [{MyApp.Shipper, queue: :events}]}

  Each sink gets every event once it's kept, agents' and the audit's, with its `"sequence"` in its
  log. Live events, like `wardrik.message.delta`, aren't kept, so they don't come.

    * It runs in the process that wrote the event, often the agent's, so return quickly.
    * An event whose node stops before the sink takes it isn't sent. Each agent's log still holds
      it: read on with `Wardrik.EventLog.page/3` from the last `"sequence"` your sink saw.
  """

  @doc "Handles one kept event. The return value is ignored."
  @callback handle_event(Wardrik.EventLog.CloudEvent.t(), opts :: term()) :: any()

  @doc false
  @spec deliver([module() | {module(), term()}], Wardrik.EventLog.CloudEvent.t()) :: :ok
  def deliver(sinks, event) do
    for sink <- sinks do
      {module, opts} = entry(sink)
      module.handle_event(event, opts)
    end

    :ok
  end

  defp entry({module, opts}), do: {module, opts}
  defp entry(module), do: {module, []}
end
