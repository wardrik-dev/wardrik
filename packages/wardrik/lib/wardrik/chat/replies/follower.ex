defmodule Wardrik.Chat.Replies.Follower do
  @moduledoc false

  use Wardrik.Listener

  @impl Wardrik.Listener
  def handle(event, listener),
    do: GenServer.call(listener.options[:server], {:event, event, listener.cursor}, :infinity)

  @impl Wardrik.Listener
  def cursor(listener), do: GenServer.call(listener.options[:server], :cursor)
end
