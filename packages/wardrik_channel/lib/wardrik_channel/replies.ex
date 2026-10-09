defmodule WardrikChannel.Replies do
  @moduledoc """
  Posts what agents answer in each room's threads, from the agents' logs, so
  nothing they answer is lost to a restart.

  Each room is a `DurableServer` keyed by its channel and its name, so one
  process in the cluster posts there, and it carries on from its store on
  another node when its own is lost. `follow/4` has it follow the agent
  answering in a thread from the end of that agent's log, and it posts, in
  the thread, as each comes:

    * what a run answered, with the messages it answers
    * the calls a run waits on, with buttons to answer them, where they are
      still waiting as it posts
    * why a run failed
    * that someone connected an account a call waited on

  `remind/3` posts again the calls a thread's agent still waits on, for a
  message that arrived behind them, which the agent will not read until
  they are answered.

  It writes down the last event of each log it has posted, so after a
  restart it posts from there: each at least once. A post the channel
  refuses is tried again, waiting longer each time up to a minute, and given
  up with a warning after the eighth attempt; the thread's later posts wait
  behind it.
  """

  alias Wardrik.AgentID
  alias WardrikChannel.Replies.Server
  alias WardrikChannel.Replies.State

  @name WardrikChannel.Replies.Rooms

  @doc false
  @spec supervisor() :: atom()
  def supervisor, do: @name

  @doc """
  The supervisor the rooms' processes run under, which a host starts once per
  node, after Wardrik and before `WardrikChannel.Supervisor`.
  """
  @spec child_spec([]) :: Supervisor.child_spec()
  def child_spec([]),
    do: %{
      DurableServer.Supervisor.child_spec(name: @name)
      | start: {__MODULE__, :start_link, [[]]}
    }

  @doc """
  Starts the supervisor the rooms' processes run under, over the store the
  fleet runs on.
  """
  @spec start_link([]) :: Supervisor.on_start()
  def start_link([]) do
    DurableServer.Supervisor.start_link(
      [name: @name, prefix: "channel_replies/", backend: WardrikStore.durable_backend()] ++
        WardrikStore.durable_shutdown()
    )
  end

  @doc """
  Posts in `thread` of `room` what `agent` answers from now on, unless the
  thread is followed already.
  """
  @spec follow(String.t(), String.t(), String.t(), AgentID.t()) :: :ok
  def follow(channel, room, thread, %AgentID{} = agent) do
    child = {Server, key: key(channel, room), initial_state: State.new(channel, room)}
    {:ok, {pid, _meta}} = DurableServer.Supervisor.ensure_started_child(@name, child)
    GenServer.call(pid, {:follow, thread, agent})
  end

  @doc """
  Posts again in `thread` of `room` the calls its agent waits on. A post
  refused is not tried again.
  """
  @spec remind(String.t(), String.t(), String.t()) :: :ok
  def remind(channel, room, thread) do
    case DurableServer.Supervisor.lookup(@name, key(channel, room)) do
      {pid, _meta} -> GenServer.cast(pid, {:remind, thread})
      nil -> :ok
    end
  end

  @doc "Posts nothing more in `room`, and forgets its threads."
  @spec forget(String.t(), String.t()) :: :ok | {:error, term()}
  def forget(channel, room),
    do: DurableServer.Supervisor.terminate_and_delete_child(@name, key(channel, room))

  defp key(channel, room), do: channel <> "/" <> room
end
