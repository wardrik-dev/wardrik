defmodule WardrikChannel.Rooms do
  @moduledoc """
  Which agent answers in each room, and how a room comes to have one.

  A room is bound by inviting the channel's bot into it, and the adapter tells
  `joined/4`, which answers what to show there:

    * `{:bound, room, offer}` - the one agent the channel offers answers
      there now, when mentioned
    * `{:choose, offers}` - several are offered, to choose among with
      `chose/4`
    * `{:create, name}` - none is, and someone there may create one for the
      room with `create/4`
    * `:none` - none is, and none may be created there

  `answers/4` changes when the room's agent answers: when mentioned,
  `:mentions`, or to every message, `:everything`. `left/3` unbinds the room,
  as taking the bot out of it, or asking it to stop answering there, does,
  and `WardrikChannel.Replies` posts nothing more in its threads.

  Each acts in a `WardrikChannel.Workspace`: a room is one of the workspace
  the channel is installed in, and what is offered there is what the host
  offers that installation. Each binding is a `WardrikChannel.Room` kept in
  the store of the host the channel runs on, and each change is recorded in
  `Wardrik.Audit` with the person who made it.
  """

  alias Wardrik.AgentID
  alias Wardrik.Audit
  alias Wardrik.Principal
  alias WardrikChannel.Offer
  alias WardrikChannel.Room
  alias WardrikChannel.Workspace

  @ns :channel_rooms

  @typedoc "What a room shows once something has changed there."
  @type shown() ::
          {:bound, Room.t(), Offer.t() | nil}
          | {:choose, [Offer.t()]}
          | {:create, String.t()}
          | :none

  @doc "The binding of `room` in the workspace, where it has one."
  @spec get(Workspace.t(), String.t()) :: Room.t() | nil
  def get(%Workspace{} = workspace, room) when is_binary(room),
    do: workspace |> store() |> WardrikStore.get(@ns, key(workspace, room))

  @doc """
  The bot was invited by `by` into `room`, known in the channel as `name`:
  binds it to the one agent the channel offers, or answers what to offer
  instead.
  """
  @spec joined(Workspace.t(), String.t(), String.t(), Principal.t() | nil) :: shown()
  def joined(%Workspace{} = workspace, room, name, by) do
    case Workspace.offered(workspace) do
      [offer] -> {:bound, bind(workspace, room, offer.agent, :mentions, by), offer}
      [] -> unoffered(workspace, name)
      offers -> {:choose, offers}
    end
  end

  @doc """
  What `room`, known as `name`, offers someone who asks to change its agent:
  the agents to choose among, or what to do where there are none.
  """
  @spec choices(Workspace.t(), String.t()) :: shown()
  def choices(%Workspace{} = workspace, name) do
    case Workspace.offered(workspace) do
      [] -> unoffered(workspace, name)
      offers -> {:choose, offers}
    end
  end

  defp unoffered(workspace, name),
    do: if(Workspace.creatable?(workspace), do: {:create, name}, else: :none)

  @doc """
  `by` chose `agent` to answer in `room`: binds the room to it, answering
  when mentioned. `{:error, :not_offered}` where the channel does not offer
  it, or no longer does.
  """
  @spec chose(Workspace.t(), String.t(), AgentID.t(), Principal.t() | nil) ::
          {:ok, Room.t(), Offer.t()} | {:error, :not_offered}
  def chose(%Workspace{} = workspace, room, %AgentID{} = agent, by) do
    case Enum.find(Workspace.offered(workspace), &(&1.agent == agent)) do
      %Offer{} = offer -> {:ok, bind(workspace, room, agent, :mentions, by), offer}
      nil -> {:error, :not_offered}
    end
  end

  @doc """
  `by` asked for an agent to be created for `room`, known as `name`: creates
  it, as the host does, and binds the room to it.
  """
  @spec create(Workspace.t(), String.t(), String.t(), Principal.t() | nil) ::
          {:ok, Room.t(), Offer.t()} | {:error, String.t()}
  def create(%Workspace{} = workspace, room, name, by) do
    if Workspace.creatable?(workspace) do
      with {:ok, %Offer{} = offer} <- Workspace.create(workspace, name, by),
           do: {:ok, bind(workspace, room, offer.agent, :mentions, by), offer}
    else
      {:error, "Agents are not created from here; whoever runs Wardrik can offer one."}
    end
  end

  @doc "`by` changed when the agent bound to `room` answers there."
  @spec answers(Workspace.t(), String.t(), Room.answers(), Principal.t() | nil) ::
          {:ok, Room.t(), Offer.t() | nil} | {:error, :not_bound}
  def answers(%Workspace{} = workspace, room, answers, by)
      when answers in [:mentions, :everything] do
    case get(workspace, room) do
      %Room{agent: agent} ->
        offer = Enum.find(Workspace.offered(workspace), &(&1.agent == agent))
        {:ok, bind(workspace, room, agent, answers, by), offer}

      nil ->
        {:error, :not_bound}
    end
  end

  @doc """
  No agent answers in `room` any longer, as `by` asked, or by taking the bot
  out of it.
  """
  @spec left(Workspace.t(), String.t(), Principal.t() | nil) :: :ok
  def left(%Workspace{} = workspace, room, by) do
    case get(workspace, room) do
      %Room{} ->
        :ok = workspace |> store() |> WardrikStore.delete(@ns, key(workspace, room))
        :ok = WardrikChannel.Replies.forget(workspace, room)
        Audit.record(audit(workspace), {:room_unbound, channel(workspace), room}, by: by)

      nil ->
        :ok
    end
  end

  defp bind(%Workspace{installation: installation} = workspace, room, agent, answers, by) do
    bound = %Room{
      channel: installation.channel,
      workspace: installation.workspace,
      room: room,
      agent: agent,
      answers: answers
    }

    {:ok, _vsn} = workspace |> store() |> WardrikStore.put(@ns, key(workspace, room), bound)

    :ok =
      Audit.record(audit(workspace), {:room_bound, bound.channel, room, agent, answers}, by: by)

    bound
  end

  defp key(%Workspace{installation: installation}, room),
    do: Enum.join([installation.channel, installation.workspace, room], "/")

  defp channel(%Workspace{installation: installation}), do: installation.channel
  defp store(%Workspace{context: context}), do: Wardrik.Host.store(context.host)
  defp audit(%Workspace{context: context}), do: Wardrik.Host.audit(context.host)
end
