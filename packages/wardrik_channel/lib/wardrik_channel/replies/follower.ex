defmodule WardrikChannel.Replies.Follower do
  @moduledoc """
  The `Wardrik.Listener` that follows one thread's agent for its room's
  `WardrikChannel.Replies.Server`: it hands the server each entry the
  thread posts from, with the cursor past it, and waits until the server
  has posted it, so one entry of a thread is in flight at a time. It reads
  on from the cursor the server keeps for the thread.

  Besides `Wardrik.Listener`'s options, it takes `:server` and `:thread`, as
  the server starts it.
  """

  use Wardrik.Listener

  @impl Wardrik.Listener
  def handle(event, %Wardrik.Listener{options: opts} = listener) do
    GenServer.call(
      Keyword.fetch!(opts, :server),
      {:event, Keyword.fetch!(opts, :thread), event, listener.cursor},
      :infinity
    )
  end

  @impl Wardrik.Listener
  def cursor(%Wardrik.Listener{options: opts}),
    do: GenServer.call(Keyword.fetch!(opts, :server), {:cursor, Keyword.fetch!(opts, :thread)})
end
