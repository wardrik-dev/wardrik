defmodule Wardrik.Sink do
  @moduledoc """
  Sends every agent's events on, to a warehouse, a queue or tracing.

      defmodule MyApp.Shipper do
        @behaviour Wardrik.Sink

        @impl true
        def handle_event(%Wardrik.Event{} = event, opts), do: MyApp.Queue.push(opts[:queue], event)
      end

  Give it to Wardrik as `sinks: [{MyApp.Shipper, queue: :events}]`.

    * A sink gets each event once it's kept, and each change the audit records. Live events, like
      `wardrik.message.delta`, aren't kept, so they don't come.
    * It runs in the process that wrote the event, often the agent's. Return quickly.
    * An event whose node stops before the sink takes it isn't sent. The agent's log still holds
      it: read on from its `sequence` with `Wardrik.Events.list/2`.
    * To follow named agents and miss nothing, use a `Wardrik.Listener`.
  """

  @doc "Handles one kept event. The return value is ignored."
  @callback handle_event(Wardrik.Event.t(), opts :: keyword()) :: any()

  @doc false
  @spec deliver([module() | {module(), keyword()}], Wardrik.EventLog.CloudEvent.t()) :: :ok
  def deliver([], _event), do: :ok

  def deliver(sinks, event) do
    event = Wardrik.Event.from_json(event)

    for sink <- sinks do
      {module, opts} = entry(sink)
      module.handle_event(event, opts)
    end

    :ok
  end

  defp entry({module, opts}), do: {module, opts}
  defp entry(module), do: {module, []}
end
