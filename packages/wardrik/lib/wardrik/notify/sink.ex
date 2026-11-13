defmodule Wardrik.Notify.Sink do
  @moduledoc false

  @behaviour Wardrik.Sink

  @types ~w(wardrik.run.interrupted wardrik.run.failed wardrik.run.completed)

  @impl Wardrik.Sink
  def handle_event(%Wardrik.Event{type: type} = event, opts) when type in @types do
    server = Keyword.fetch!(opts, :server)
    GenServer.cast(server, {:event, event})
  end

  def handle_event(_event, _opts), do: :ok
end
