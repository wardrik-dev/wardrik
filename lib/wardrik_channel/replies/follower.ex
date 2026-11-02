defmodule WardrikChannel.Replies.Follower do
  @moduledoc """
  Follows the conversations of a room's threads for its `WardrikChannel.Replies.Server`.

  Hands the server each event and waits until it's posted, so one event is in flight at a time.
  """

  use WardrikEvents.Listener

  @impl WardrikEvents.Listener
  def handle(event, listener) do
    event = Wardrik.Event.from_json(event)
    GenServer.call(listener.options[:server], {:event, event, listener.cursor}, :infinity)
  end

  @impl WardrikEvents.Listener
  def cursor(listener), do: GenServer.call(listener.options[:server], :cursor)
end
