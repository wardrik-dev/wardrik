defmodule WardrikChannel.Replies.Follower do
  @moduledoc false

  use WardrikEvents.Listener

  @impl WardrikEvents.Listener
  def handle(event, listener) do
    event = Wardrik.Event.from_json(event)
    GenServer.call(listener.options[:server], {:event, event, listener.cursor}, :infinity)
  end

  @impl WardrikEvents.Listener
  def cursor(listener), do: GenServer.call(listener.options[:server], :cursor)
end
