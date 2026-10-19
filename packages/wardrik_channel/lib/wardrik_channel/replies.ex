defmodule WardrikChannel.Replies do
  @moduledoc """
  Posts what agents answer in each room's threads, from the agents' logs, so
  nothing they answer is lost to a restart.

  Each room is a `DurableServer` keyed by its channel, its workspace and its
  name, so one
  process in the cluster posts there, and it carries on from its store on
  another node when its own is lost. `follow/4` has it follow the agent
  answering in a thread from the end of that agent's log, and it posts, in
  the thread, as each comes:

    * what a run answered, with the messages it answers
    * the calls a run waits on, with buttons to answer them, where they are
      still waiting as it posts: asked of each of the channel's approvers
      directly, with who it waits on said in the thread, where the channel
      names approvers
    * why a run failed
    * that someone connected an account a call waited on
    * who decided a call, and how, wherever they decided it
    * that a run stopped before it answered, with the messages it would
      have answered

  While a thread's agent works, and waits on nobody, it has the channel
  show what the agent is doing as the thread's status, worded by a
  `Wardrik.Agent.Activity.Presenter` and read from the agent as it is
  shown, so the latest is: at most once a throttle, a change within one as
  it ends, and again after a refresh while it stands unchanged. What is
  posted next in the thread takes it away, and a run stopped clears it. A
  status, or a run stopped, that the channel refuses is not tried again.

  `remind/3` posts again the calls a thread's agent still waits on, for a
  message that arrived behind them, which the agent will not read until
  they are answered.

  It writes down the last event of each log it has posted, so after a
  restart it posts from there: each at least once. What it posts through,
  each `WardrikChannel.Channel`, is handed to it as it starts, and never
  written down; the installation of the room's workspace, with its token,
  is found as each post is made, so a workspace taken out has nothing
  more posted in it. A post the channel
  refuses is tried again, waiting longer each time up to a minute, and given
  up with a warning after the eighth attempt; the thread's later posts wait
  behind it.
  """

  alias Wardrik.AgentID
  alias WardrikChannel.Replies.Server
  alias WardrikChannel.Replies.State
  alias WardrikChannel.Room

  @name WardrikChannel.Replies.Rooms

  @throttle 2_000
  @refresh 90_000

  @doc "The name it runs under unless started with another."
  @spec supervisor() :: atom()
  def supervisor, do: @name

  @doc """
  The supervisor the rooms' processes run under, which a host starts once per
  node, after Wardrik and before `WardrikChannel.Supervisor`. Options:

    * `:channels` - the channels it posts in, as `WardrikChannel.channels/2`
      makes them, handed to each room's process as it starts, wakes, or
      restarts on another node; required
    * `:store` - the `WardrikStore` the fleet runs on, which the rooms are
      kept in; required
    * `:name` - what it runs under, `supervisor/0` unless given; a channel's
      context names it as `:replies`
    * `:presenter` - the `Wardrik.Agent.Activity.Presenter` a thread's
      status is worded by, `Wardrik.Agent.Activity.English` unless given
    * `:throttle` - the least time between two of a thread's statuses, in
      milliseconds, 2 seconds unless given
    * `:refresh` - how long after it is shown a status that stands
      unchanged is shown again, in milliseconds, longer than `:throttle`:
      90 seconds unless given, within the two minutes a channel such as
      Slack shows one
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @name)

    %{
      DurableServer.Supervisor.child_spec(name: name)
      | start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Starts the supervisor the rooms' processes run under, over the store the
  fleet runs on. Each runs under its own prefix in the store, by its name.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts, [
        :channels,
        :store,
        name: @name,
        presenter: %Wardrik.Agent.Activity.English{},
        throttle: @throttle,
        refresh: @refresh
      ])

    name = Keyword.fetch!(opts, :name)

    DurableServer.Supervisor.start_link(
      [
        name: name,
        prefix: "channel_replies/#{inspect(name)}/",
        backend: opts |> Keyword.fetch!(:store) |> WardrikStore.durable_backend(),
        init_info: %{
          channels: Keyword.fetch!(opts, :channels),
          showing: Map.new(Keyword.take(opts, [:presenter, :throttle, :refresh]))
        }
      ] ++ WardrikStore.durable_shutdown()
    )
  end

  @doc """
  Posts in `thread` of the room what `agent` answers from now on, unless
  the thread is followed already.
  """
  @spec follow(Room.t(), String.t(), AgentID.t()) :: :ok
  def follow(%Room{workspace: %{installation: installation}} = room, thread, %AgentID{} = agent) do
    state = State.new(installation.channel, installation.workspace, room.id)
    child = {Server, key: Room.key(room), initial_state: state}
    {:ok, {pid, _meta}} = DurableServer.Supervisor.ensure_started_child(replies(room), child)
    GenServer.call(pid, {:follow, thread, agent})
  end

  @doc """
  Posts again in `thread` of the room the calls its agent waits on. A post
  refused is not tried again.
  """
  @spec remind(Room.t(), String.t()) :: :ok
  def remind(%Room{} = room, thread) do
    case DurableServer.Supervisor.lookup(replies(room), Room.key(room)) do
      {pid, _meta} -> GenServer.cast(pid, {:remind, thread})
      nil -> :ok
    end
  end

  @doc "Posts nothing more in the room, and forgets its threads."
  @spec forget(Room.t()) :: :ok | {:error, term()}
  def forget(%Room{} = room),
    do: DurableServer.Supervisor.terminate_and_delete_child(replies(room), Room.key(room))

  defp replies(%Room{workspace: workspace}), do: workspace.context.replies
end
