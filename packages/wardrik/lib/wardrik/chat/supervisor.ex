defmodule Wardrik.Chat.Supervisor do
  @moduledoc """
  Runs a channel.

  Starts the processes that post in its rooms, then the adapter's `c:Wardrik.Chat.children/1`.
  """

  use Supervisor

  alias Wardrik.Chat.Channel

  @doc "Starts `adapter`'s channel with the options Wardrik passes it."
  @spec start_link({module(), keyword()}) :: Supervisor.on_start()
  def start_link({adapter, opts}),
    do: Supervisor.start_link(__MODULE__, Channel.new(adapter, opts))

  @impl Supervisor
  def init(%Channel{adapter: adapter} = channel) do
    children = [Wardrik.Chat.Replies.child_spec(channel) | adapter.children(channel)]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
