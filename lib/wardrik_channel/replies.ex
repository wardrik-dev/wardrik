defmodule WardrikChannel.Replies do
  @moduledoc """
  Posts agents' answers in each room's threads.

  Each room has one `WardrikChannel.Replies.Server` in the cluster, kept in Wardrik's store. It
  reads the log of each conversation its threads hold, and no other, so no answer is lost to a
  restart. It posts:

    * what a run answered
    * what the agent is doing while it works
    * the calls it waits on, and who decided them
    * why a run failed, or that it stopped
  """

  alias WardrikChannel.Channel
  alias WardrikChannel.Replies.Server
  alias WardrikChannel.Replies.State
  alias WardrikChannel.Workspace

  @doc "Returns the child spec of the supervisor the channel's rooms run under."
  @spec child_spec(Channel.t()) :: Supervisor.child_spec()
  def child_spec(%Channel{} = channel) do
    [
      name: supervisor(channel),
      prefix: "#{channel.name}/replies/",
      backend: {WardrikStore.Durable, store: channel.store},
      init_info: %{channel: channel}
    ]
    |> DurableServer.Supervisor.child_spec()
    |> Map.put(:id, __MODULE__)
  end

  @doc """
  Starts posting what `:agent` does in `:conversation`, in its thread of `:room`. Does nothing if
  it already is.

      WardrikChannel.Replies.follow(workspace,
        room: "C024BE91L",
        agent: "agt_01JF8X5RQ2",
        conversation: "slack.T0123.C024BE91L.1696.1234"
      )
  """
  @spec follow(Workspace.t(), room: String.t(), agent: String.t(), conversation: String.t()) ::
          :ok
  def follow(%Workspace{channel: channel, installation: installation} = workspace, opts) do
    room = Keyword.fetch!(opts, :room)

    child =
      {Server, key: key(workspace, room), initial_state: State.new(installation.workspace, room)}

    {:ok, {pid, _meta}} =
      DurableServer.Supervisor.ensure_started_child(supervisor(channel), child)

    GenServer.call(pid, {:follow, held(opts)})
  end

  @doc """
  Posts the calls `:agent` waits on in `:conversation` again, in its thread of `:room`.

      WardrikChannel.Replies.remind(workspace,
        room: "C024BE91L",
        agent: "agt_01JF8X5RQ2",
        conversation: "slack.T0123.C024BE91L.1696.1234"
      )
  """
  @spec remind(Workspace.t(), room: String.t(), agent: String.t(), conversation: String.t()) ::
          :ok
  def remind(%Workspace{channel: channel} = workspace, opts) do
    room = Keyword.fetch!(opts, :room)

    case DurableServer.Supervisor.lookup(supervisor(channel), key(workspace, room)) do
      {pid, _meta} -> GenServer.cast(pid, {:remind, held(opts)})
      nil -> :ok
    end
  end

  defp held(opts), do: {Keyword.fetch!(opts, :agent), Keyword.fetch!(opts, :conversation)}

  @doc "Stops posting in `room` and deletes its saved position."
  @spec forget(Workspace.t(), String.t()) :: :ok
  def forget(%Workspace{channel: channel} = workspace, room) do
    _deleted =
      DurableServer.Supervisor.terminate_and_delete_child(
        supervisor(channel),
        key(workspace, room)
      )

    :ok
  end

  defp supervisor(%Channel{wardrik: wardrik, name: name}),
    do: Module.concat([wardrik, "Channels", name, "Replies"])

  defp key(%Workspace{installation: installation}, room),
    do: installation.workspace <> "/" <> room
end
