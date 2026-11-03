defmodule Wardrik.Notify.Sink do
  @moduledoc false

  @behaviour WardrikEvents.Sink

  @types ~w(wardrik.tool_call.started wardrik.run.interrupted wardrik.run.failed
            wardrik.run.completed wardrik.run.cancelled)

  @impl WardrikEvents.Sink
  def handle_event(%{"type" => type} = event, notifier) when type in @types,
    do: GenServer.cast(notifier, {:event, event})

  def handle_event(_event, _notifier), do: :ok
end
