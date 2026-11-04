defmodule Wardrik.Notify.Sink do
  @moduledoc false

  @behaviour WardrikEvents.Sink

  @types ~w(wardrik.tool_call.started wardrik.run.interrupted wardrik.run.failed
            wardrik.run.completed wardrik.run.cancelled)

  # A named conversation, such as a chat thread, is answered where it was opened.
  @impl WardrikEvents.Sink
  def handle_event(%{"conversation" => conversation}, _notifier) when is_binary(conversation),
    do: :ok

  def handle_event(%{"type" => type} = event, notifier) when type in @types,
    do: GenServer.cast(notifier, {:event, event})

  def handle_event(_event, _notifier), do: :ok
end
