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

  Each acts on a `WardrikChannel.Place`, a room of a workspace the channel
  is installed in, and what is offered there is what the host offers that
  installation. Who made a change is each one's `:by`. Each binding is a `WardrikChannel.Room` kept in
  the store of the host the channel runs on, and each change is recorded in
  `Wardrik.Audit` with the person who made it.
  """

  alias Wardrik.AgentID
  alias Wardrik.Audit
  alias WardrikChannel.Offer
  alias WardrikChannel.Place
  alias WardrikChannel.Room
  alias WardrikChannel.Workspace

  @ns :channel_rooms

  @typedoc "What a room shows once something has changed there."
  @type shown() ::
          {:bound, Room.t(), Offer.t() | nil}
          | {:choose, [Offer.t()]}
          | {:create, String.t()}
          | :none

  @doc "The binding of the place, where it has one."
  @spec get(Place.t()) :: Room.t() | nil
  def get(%Place{} = place), do: place |> store() |> WardrikStore.get(@ns, Place.key(place))

  @doc """
  The bot was invited into the place: binds it to the one agent the
  channel offers, or answers what to offer instead. Options:

    * `:name` - what the room is called in the channel, its id unless given
    * `:by` - who invited it, where the channel says
  """
  @spec joined(Place.t(), keyword()) :: shown()
  def joined(%Place{workspace: workspace} = place, opts \\ []) do
    opts = Keyword.validate!(opts, [:name, :by])

    case Workspace.offered(workspace) do
      [offer] -> {:bound, bind(place, offer.agent, :mentions, opts[:by]), offer}
      [] -> unoffered(place, opts[:name])
      offers -> {:choose, offers}
    end
  end

  @doc """
  What the place offers someone who asks to change its agent: the agents to
  choose among, or what to do where there are none. Options: `:name`, what
  the room is called in the channel, its id unless given.
  """
  @spec choices(Place.t(), keyword()) :: shown()
  def choices(%Place{workspace: workspace} = place, opts \\ []) do
    opts = Keyword.validate!(opts, [:name])

    case Workspace.offered(workspace) do
      [] -> unoffered(place, opts[:name])
      offers -> {:choose, offers}
    end
  end

  defp unoffered(%Place{workspace: workspace, room: room}, name),
    do: if(Workspace.creatable?(workspace), do: {:create, name || room}, else: :none)

  @doc """
  `agent` was chosen to answer in the place: binds it, answering when
  mentioned. `{:error, :not_offered}` where the channel does not offer it,
  or no longer does. Options: `:by`, who chose it.
  """
  @spec chose(Place.t(), AgentID.t(), keyword()) ::
          {:ok, Room.t(), Offer.t()} | {:error, :not_offered}
  def chose(%Place{workspace: workspace} = place, %AgentID{} = agent, opts \\ []) do
    opts = Keyword.validate!(opts, [:by])

    case Enum.find(Workspace.offered(workspace), &(&1.agent == agent)) do
      %Offer{} = offer -> {:ok, bind(place, agent, :mentions, opts[:by]), offer}
      nil -> {:error, :not_offered}
    end
  end

  @doc """
  Someone asked for an agent to be created for the place, named after
  `name`: creates it, as the host does, and binds the place to it. Options:
  `:by`, who asked.
  """
  @spec create(Place.t(), String.t(), keyword()) ::
          {:ok, Room.t(), Offer.t()} | {:error, String.t()}
  def create(%Place{workspace: workspace} = place, name, opts \\ []) when is_binary(name) do
    opts = Keyword.validate!(opts, [:by])

    if Workspace.creatable?(workspace) do
      with {:ok, %Offer{} = offer} <- Workspace.create(workspace, name, by: opts[:by]),
           do: {:ok, bind(place, offer.agent, :mentions, opts[:by]), offer}
    else
      {:error, "Agents are not created from here; whoever runs Wardrik can offer one."}
    end
  end

  @doc """
  Changes when the agent bound to the place answers. Options: `:by`, who
  changed it.
  """
  @spec answers(Place.t(), Room.answers(), keyword()) ::
          {:ok, Room.t(), Offer.t() | nil} | {:error, :not_bound}
  def answers(%Place{workspace: workspace} = place, answers, opts \\ [])
      when answers in [:mentions, :everything] do
    opts = Keyword.validate!(opts, [:by])

    case get(place) do
      %Room{agent: agent} ->
        offer = Enum.find(Workspace.offered(workspace), &(&1.agent == agent))
        {:ok, bind(place, agent, answers, opts[:by]), offer}

      nil ->
        {:error, :not_bound}
    end
  end

  @doc """
  No agent answers in the place any longer, as someone asked, or as taking
  the bot out of it does. Options: `:by`, who asked, where the channel says.
  """
  @spec left(Place.t(), keyword()) :: :ok
  def left(%Place{} = place, opts \\ []) do
    opts = Keyword.validate!(opts, [:by])

    case get(place) do
      %Room{channel: channel, room: room} ->
        :ok = place |> store() |> WardrikStore.delete(@ns, Place.key(place))
        :ok = WardrikChannel.Replies.forget(place)
        Audit.record(audit(place), {:room_unbound, channel, room}, by: opts[:by])

      nil ->
        :ok
    end
  end

  defp bind(%Place{workspace: workspace, room: room} = place, agent, answers, by) do
    %{installation: installation} = workspace

    bound = %Room{
      channel: installation.channel,
      workspace: installation.workspace,
      room: room,
      agent: agent,
      answers: answers
    }

    {:ok, _vsn} = place |> store() |> WardrikStore.put(@ns, Place.key(place), bound)

    :ok =
      Audit.record(audit(place), {:room_bound, bound.channel, room, agent, answers}, by: by)

    bound
  end

  defp store(%Place{workspace: workspace}), do: Wardrik.Host.store(workspace.context.host)
  defp audit(%Place{workspace: workspace}), do: Wardrik.Host.audit(workspace.context.host)
end
