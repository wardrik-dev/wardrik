defmodule Wardrik.Chat.Replies.Follower do
  @moduledoc false

  use Wardrik.EventLog.Listener

  @impl Wardrik.EventLog.Listener
  def handle(event, listener) do
    event = Wardrik.Event.from_json(event)
    GenServer.call(listener.options[:server], {:event, event, listener.cursor}, :infinity)
  end

  @impl Wardrik.EventLog.Listener
  def cursor(listener), do: GenServer.call(listener.options[:server], :cursor)
end
