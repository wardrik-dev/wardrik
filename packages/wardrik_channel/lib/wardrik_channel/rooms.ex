defmodule WardrikChannel.Rooms do
  @moduledoc """
  Which agent answers in each room, and how a room comes to have one.

  A room is bound by inviting the channel's bot into it, and the adapter tells
  `joined/2`, which answers what to show there:

    * `{:bound, room, offer}` - the one agent the channel offers answers
      there now, when mentioned
    * `{:choose, offers}` - several are offered, to choose among with
      `chose/3`
    * `{:create, name}` - none is, and someone there may create one for the
      room with `create/3`
    * `:none` - none is, and none may be created there

  `answers/3` changes when the room's agent answers: when mentioned,
  `:mentions`, or to every message, `:everything`. `left/2` unbinds the room,
  as taking the bot out of it, or asking it to stop answering there, does,
  and `WardrikChannel.Replies` posts nothing more in its threads.

  Each acts on a `WardrikChannel.Room`, a room of a workspace the channel
  is installed in, and what is offered there is what the host offers that
  installation. Who made a change is each one's `:by`. Each binding is a
  `WardrikChannel.Binding` kept in the store of the host the channel runs
  on, and each change is recorded in `Wardrik.Audit` with the person who
  made it.
  """

  alias Wardrik.AgentID
  alias Wardrik.Audit
  alias WardrikChannel.Binding
  alias WardrikChannel.Installation
  alias WardrikChannel.Offer
  alias WardrikChannel.Room
  alias WardrikChannel.Workspace

  @ns :channel_rooms

  @typedoc "What a room shows once something has changed there."
  @type shown() ::
          {:bound, Binding.t(), Offer.t() | nil}
          | {:choose, [Offer.t()]}
          | {:create, String.t()}
          | :none

  @doc """
  What the room is bound to, where it is bound to an agent its workspace's
  installation covers: a room of a workspace installed again, for another
  owner, is not bound to the agent it was before.
  """
  @spec get(Room.t()) :: Binding.t() | nil
  def get(%Room{workspace: workspace} = room) do
    case room |> store() |> WardrikStore.get(@ns, Room.key(room)) do
      %Binding{agent: agent} = binding ->
        if Installation.covers?(workspace.installation, agent), do: binding

      nil ->
        nil
    end
  end

  @doc """
  The bot was invited into the room: binds it to the one agent the
  channel offers, or answers what to offer instead. Options:

    * `:name` - what the room is called in the channel, its id unless given
    * `:by` - who invited it, where the channel says
  """
  @spec joined(Room.t(), keyword()) :: shown()
  def joined(%Room{workspace: workspace} = room, opts \\ []) do
    opts = Keyword.validate!(opts, [:name, :by])

    case Workspace.offered(workspace) do
      [offer] -> {:bound, bind(room, offer.agent, :mentions, opts[:by]), offer}
      [] -> unoffered(room, opts[:name])
      offers -> {:choose, offers}
    end
  end

  @doc """
  What the room offers someone who asks to change its agent: the agents to
  choose among, or what to do where there are none. Options: `:name`, what
  the room is called in the channel, its id unless given.
  """
  @spec choices(Room.t(), keyword()) :: shown()
  def choices(%Room{workspace: workspace} = room, opts \\ []) do
    opts = Keyword.validate!(opts, [:name])

    case Workspace.offered(workspace) do
      [] -> unoffered(room, opts[:name])
      offers -> {:choose, offers}
    end
  end

  defp unoffered(%Room{workspace: workspace, id: id}, name),
    do: if(Workspace.creatable?(workspace), do: {:create, name || id}, else: :none)

  @doc """
  `agent` was chosen to answer in the room: binds it, answering when
  mentioned. `{:error, :not_offered}` where the channel does not offer it,
  or no longer does. Options: `:by`, who chose it.
  """
  @spec chose(Room.t(), AgentID.t(), keyword()) ::
          {:ok, Binding.t(), Offer.t()} | {:error, :not_offered}
  def chose(%Room{workspace: workspace} = room, %AgentID{} = agent, opts \\ []) do
    opts = Keyword.validate!(opts, [:by])

    case Enum.find(Workspace.offered(workspace), &(&1.agent == agent)) do
      %Offer{} = offer -> {:ok, bind(room, agent, :mentions, opts[:by]), offer}
      nil -> {:error, :not_offered}
    end
  end

  @doc """
  Someone asked for an agent to be created for the room, named after
  `name`: creates it, as the host does, and binds the room to it. Options:
  `:by`, who asked.
  """
  @spec create(Room.t(), String.t(), keyword()) ::
          {:ok, Binding.t(), Offer.t()} | {:error, String.t()}
  def create(%Room{workspace: workspace} = room, name, opts \\ []) when is_binary(name) do
    opts = Keyword.validate!(opts, [:by])

    if Workspace.creatable?(workspace) do
      with {:ok, %Offer{} = offer} <- Workspace.create(workspace, name, by: opts[:by]),
           do: {:ok, bind(room, offer.agent, :mentions, opts[:by]), offer}
    else
      {:error, "Agents are not created from here. " <> Workspace.offering(workspace)}
    end
  end

  @doc """
  Changes when the agent bound to the room answers. Options: `:by`, who
  changed it.
  """
  @spec answers(Room.t(), Binding.answers(), keyword()) ::
          {:ok, Binding.t(), Offer.t() | nil} | {:error, :not_bound}
  def answers(%Room{workspace: workspace} = room, answers, opts \\ [])
      when answers in [:mentions, :everything] do
    opts = Keyword.validate!(opts, [:by])

    case get(room) do
      %Binding{agent: agent} ->
        offer = Enum.find(Workspace.offered(workspace), &(&1.agent == agent))
        {:ok, bind(room, agent, answers, opts[:by]), offer}

      nil ->
        {:error, :not_bound}
    end
  end

  @doc """
  No agent answers in the room any longer, as someone asked, or as taking
  the bot out of it does. Options: `:by`, who asked, where the channel says.
  """
  @spec left(Room.t(), keyword()) :: :ok
  def left(%Room{} = room, opts \\ []) do
    opts = Keyword.validate!(opts, [:by])

    case get(room) do
      %Binding{channel: channel, room: id} ->
        :ok = room |> store() |> WardrikStore.delete(@ns, Room.key(room))
        :ok = WardrikChannel.Replies.forget(room)
        Audit.record(audit(room), {:room_unbound, channel, id}, by: opts[:by])

      nil ->
        :ok
    end
  end

  defp bind(%Room{workspace: workspace, id: id} = room, agent, answers, by) do
    %{installation: installation} = workspace

    bound = %Binding{
      channel: installation.channel,
      workspace: installation.workspace,
      room: id,
      agent: agent,
      answers: answers
    }

    {:ok, _vsn} = room |> store() |> WardrikStore.put(@ns, Room.key(room), bound)

    :ok = Audit.record(audit(room), {:room_bound, bound.channel, id, agent, answers}, by: by)

    bound
  end

  defp store(%Room{workspace: workspace}), do: Wardrik.Host.store(workspace.context.host)
  defp audit(%Room{workspace: workspace}), do: Wardrik.Host.audit(workspace.context.host)
end
