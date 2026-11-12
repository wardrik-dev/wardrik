defmodule Wardrik.Notify.Sink do
  @moduledoc false

  @behaviour Wardrik.Sink

  @types ~w(wardrik.run.interrupted wardrik.run.failed wardrik.run.completed)

  @impl Wardrik.Sink
  def handle_event(%Wardrik.Event{type: type} = event, opts) when type in @types,
    do: GenServer.cast(Keyword.fetch!(opts, :server), {:event, event})

  def handle_event(_event, _opts), do: :ok
end
