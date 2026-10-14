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
      still waiting as it posts: asked of each of the channel's approvers
      directly, with who it waits on said in the thread, where the channel
      names approvers
    * why a run failed
    * that someone connected an account a call waited on
    * who decided a call, and how, wherever they decided it

  `remind/3` posts again the calls a thread's agent still waits on, for a
  message that arrived behind them, which the agent will not read until
  they are answered.

  It writes down the last event of each log it has posted, so after a
  restart it posts from there: each at least once. What it posts through,
  each channel's adapter, options and context, is handed to it as it
  starts, and never written down. A post the channel
  refuses is tried again, waiting longer each time up to a minute, and given
  up with a warning after the eighth attempt; the thread's later posts wait
  behind it.
  """

  alias Wardrik.AgentID
  alias WardrikChannel.Context
  alias WardrikChannel.Replies.Server
  alias WardrikChannel.Replies.State

  @name WardrikChannel.Replies.Rooms

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
    opts = Keyword.validate!(opts, [:channels, :store, name: @name])
    name = Keyword.fetch!(opts, :name)

    DurableServer.Supervisor.start_link(
      [
        name: name,
        prefix: "channel_replies/#{inspect(name)}/",
        backend: opts |> Keyword.fetch!(:store) |> WardrikStore.durable_backend(),
        init_info: %{channels: Keyword.fetch!(opts, :channels)}
      ] ++ WardrikStore.durable_shutdown()
    )
  end

  @doc """
  Posts in `thread` of `room` what `agent` answers from now on, unless the
  thread is followed already, in the context's channel.
  """
  @spec follow(Context.t(), String.t(), String.t(), AgentID.t()) :: :ok
  def follow(%Context{channel: channel, replies: replies}, room, thread, %AgentID{} = agent) do
    child = {Server, key: key(channel, room), initial_state: State.new(channel, room)}
    {:ok, {pid, _meta}} = DurableServer.Supervisor.ensure_started_child(replies, child)
    GenServer.call(pid, {:follow, thread, agent})
  end

  @doc """
  Posts again in `thread` of `room` the calls its agent waits on. A post
  refused is not tried again.
  """
  @spec remind(Context.t(), String.t(), String.t()) :: :ok
  def remind(%Context{channel: channel, replies: replies}, room, thread) do
    case DurableServer.Supervisor.lookup(replies, key(channel, room)) do
      {pid, _meta} -> GenServer.cast(pid, {:remind, thread})
      nil -> :ok
    end
  end

  @doc "Posts nothing more in `room` of the context's channel, and forgets its threads."
  @spec forget(Context.t(), String.t()) :: :ok | {:error, term()}
  def forget(%Context{channel: channel, replies: replies}, room),
    do: DurableServer.Supervisor.terminate_and_delete_child(replies, key(channel, room))

  defp key(channel, room), do: channel <> "/" <> room
end
