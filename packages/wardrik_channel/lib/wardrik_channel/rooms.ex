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

  Each binding is a `WardrikChannel.Room` kept in `WardrikStore`, and each
  change is recorded in `Wardrik.Audit` with the person who made it.
  """

  alias Wardrik.AgentID
  alias Wardrik.Audit
  alias Wardrik.Principal
  alias WardrikChannel.Context
  alias WardrikChannel.Offer
  alias WardrikChannel.Room

  @ns :channel_rooms

  @typedoc "What a room shows once something has changed there."
  @type shown() ::
          {:bound, Room.t(), Offer.t() | nil}
          | {:choose, [Offer.t()]}
          | {:create, String.t()}
          | :none

  @doc "The binding of `room` in the context's channel, where it has one."
  @spec get(Context.t(), String.t()) :: Room.t() | nil
  def get(%Context{channel: channel}, room) when is_binary(room),
    do: WardrikStore.get(@ns, key(channel, room))

  @doc """
  The bot was invited by `by` into `room`, known in the channel as `name`:
  binds it to the one agent the channel offers, or answers what to offer
  instead.
  """
  @spec joined(Context.t(), String.t(), String.t(), Principal.t() | nil) :: shown()
  def joined(%Context{} = context, room, name, by) do
    case Context.offered(context) do
      [offer] -> {:bound, bind(context, room, offer.agent, :mentions, by), offer}
      [] -> unoffered(context, name)
      offers -> {:choose, offers}
    end
  end

  @doc """
  What `room`, known as `name`, offers someone who asks to change its agent:
  the agents to choose among, or what to do where there are none.
  """
  @spec choices(Context.t(), String.t()) :: shown()
  def choices(%Context{} = context, name) do
    case Context.offered(context) do
      [] -> unoffered(context, name)
      offers -> {:choose, offers}
    end
  end

  defp unoffered(context, name),
    do: if(Context.creatable?(context), do: {:create, name}, else: :none)

  @doc """
  `by` chose `agent` to answer in `room`: binds the room to it, answering
  when mentioned. `{:error, :not_offered}` where the channel does not offer
  it, or no longer does.
  """
  @spec chose(Context.t(), String.t(), AgentID.t(), Principal.t() | nil) ::
          {:ok, Room.t(), Offer.t()} | {:error, :not_offered}
  def chose(%Context{} = context, room, %AgentID{} = agent, by) do
    case Enum.find(Context.offered(context), &(&1.agent == agent)) do
      %Offer{} = offer -> {:ok, bind(context, room, agent, :mentions, by), offer}
      nil -> {:error, :not_offered}
    end
  end

  @doc """
  `by` asked for an agent to be created for `room`, known as `name`: creates
  it, as the host does, and binds the room to it.
  """
  @spec create(Context.t(), String.t(), String.t(), Principal.t() | nil) ::
          {:ok, Room.t(), Offer.t()} | {:error, String.t()}
  def create(%Context{} = context, room, name, by) do
    if Context.creatable?(context) do
      with {:ok, %Offer{} = offer} <- Context.create(context, name, by),
           do: {:ok, bind(context, room, offer.agent, :mentions, by), offer}
    else
      {:error, "Agents are not created from here; whoever runs Wardrik can offer one."}
    end
  end

  @doc "`by` changed when the agent bound to `room` answers there."
  @spec answers(Context.t(), String.t(), Room.answers(), Principal.t() | nil) ::
          {:ok, Room.t(), Offer.t() | nil} | {:error, :not_bound}
  def answers(%Context{} = context, room, answers, by) when answers in [:mentions, :everything] do
    case get(context, room) do
      %Room{agent: agent} ->
        offer = Enum.find(Context.offered(context), &(&1.agent == agent))
        {:ok, bind(context, room, agent, answers, by), offer}

      nil ->
        {:error, :not_bound}
    end
  end

  @doc """
  No agent answers in `room` any longer, as `by` asked, or by taking the bot
  out of it.
  """
  @spec left(Context.t(), String.t(), Principal.t() | nil) :: :ok
  def left(%Context{channel: channel} = context, room, by) do
    case get(context, room) do
      %Room{} ->
        :ok = WardrikStore.delete(@ns, key(channel, room))
        :ok = WardrikChannel.Replies.forget(channel, room)
        Audit.record({:room_unbound, channel, room}, by)

      nil ->
        :ok
    end
  end

  defp bind(%Context{channel: channel}, room, agent, answers, by) do
    bound = %Room{channel: channel, room: room, agent: agent, answers: answers}
    {:ok, _vsn} = WardrikStore.put(@ns, key(channel, room), bound)
    :ok = Audit.record({:room_bound, channel, room, agent, answers}, by)
    bound
  end

  defp key(channel, room), do: channel <> "/" <> room
end
