defmodule WardrikChannel.Rooms do
  @moduledoc """
  Which agent answers in each room, and how a room comes to have one.

  A room is bound by inviting the channel's bot into it. The adapter tells
  `joined/3`, which binds the room at once to the one agent the channel
  offers, or answers the agents to choose among, which the adapter offers in
  the room and hands the choice to `chose/4`. Taking the bot out of the room
  unbinds it, through `left/3`. `answers/4` changes when the agent answers:
  when mentioned, `:mentions`, as a room starts, or to every message,
  `:everything`.

  Each binding is a `WardrikChannel.Room` kept in `WardrikStore`, and each
  change is recorded in `Wardrik.Audit` with the person who made it.
  """

  alias Wardrik.AgentID
  alias Wardrik.Audit
  alias Wardrik.Principal
  alias WardrikChannel.Context
  alias WardrikChannel.Room

  @ns :channel_rooms

  @doc "The binding of `room` in the context's channel, where it has one."
  @spec get(Context.t(), String.t()) :: Room.t() | nil
  def get(%Context{channel: channel}, room) when is_binary(room),
    do: WardrikStore.get(@ns, key(channel, room))

  @doc """
  The bot was invited into `room` by `by`: binds it to the one agent the
  channel offers, or answers the agents to choose among, or none.
  """
  @spec joined(Context.t(), String.t(), Principal.t() | nil) ::
          {:bound, Room.t()} | {:choose, [AgentID.t()]}
  def joined(%Context{} = context, room, by) do
    case Context.offered(context) do
      [agent] -> {:bound, bind(context, room, agent, :mentions, by)}
      agents -> {:choose, agents}
    end
  end

  @doc """
  `by` chose `agent` to answer in `room`, among those `joined/3` offered:
  binds the room to it, answering when mentioned. `{:error, :not_offered}`
  where the channel does not offer it, or no longer does.
  """
  @spec chose(Context.t(), String.t(), AgentID.t(), Principal.t() | nil) ::
          {:ok, Room.t()} | {:error, :not_offered}
  def chose(%Context{} = context, room, %AgentID{} = agent, by) do
    if agent in Context.offered(context),
      do: {:ok, bind(context, room, agent, :mentions, by)},
      else: {:error, :not_offered}
  end

  @doc "`by` changed when the agent bound to `room` answers there."
  @spec answers(Context.t(), String.t(), Room.answers(), Principal.t() | nil) ::
          {:ok, Room.t()} | {:error, :not_bound}
  def answers(%Context{} = context, room, answers, by) when answers in [:mentions, :everything] do
    case get(context, room) do
      %Room{agent: agent} -> {:ok, bind(context, room, agent, answers, by)}
      nil -> {:error, :not_bound}
    end
  end

  @doc "The bot was taken out of `room` by `by`: no agent answers there any longer."
  @spec left(Context.t(), String.t(), Principal.t() | nil) :: :ok
  def left(%Context{channel: channel}, room, by) do
    case WardrikStore.get(@ns, key(channel, room)) do
      %Room{} ->
        :ok = WardrikStore.delete(@ns, key(channel, room))
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
