defmodule Wardrik.Notify.Sink do
  @moduledoc false

  @behaviour Wardrik.EventLog.Sink

  @types ~w(wardrik.run.interrupted wardrik.run.failed wardrik.run.completed)

  @impl Wardrik.EventLog.Sink
  def handle_event(%{"type" => type} = event, notifier) when type in @types,
    do: GenServer.cast(notifier, {:event, event})

  def handle_event(_event, _notifier), do: :ok
end
