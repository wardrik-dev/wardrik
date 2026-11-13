defmodule Wardrik.Chat.Rooms do
  @moduledoc """
  Keeps which agent answers in each room, and the threads it has answered in.

      # The bot was invited into the room
      Wardrik.Chat.Rooms.joined(workspace, room, member)
      #=> {:bound, binding, offer}  # one agent offered; it now answers when mentioned
      #=> {:choose, offers}         # several offered; show them to pick from
      #=> :none                     # none offered

      # Someone picked an agent
      {:ok, binding, offer} =
        Wardrik.Chat.Rooms.chose(workspace, room: room, agent: "agt_01JF8X5RQ2", by: member)

      # Answer every message, not only mentions
      {:ok, binding} = Wardrik.Chat.Rooms.answers(workspace, room, :everything, member)

      # The bot left the room
      :ok = Wardrik.Chat.Rooms.left(workspace, room, member)

    * Each change is recorded in the audit as `wardrik.room.bound` or `wardrik.room.unbound`.
    * Pass the `member` who made it, or `nil` if the adapter doesn't know.
    * A member is offered the agents they may read. See `Wardrik.Chat.Workspace.offered/2`.
  """

  alias Wardrik.Chat.Binding
  alias Wardrik.Chat.Member
  alias Wardrik.Chat.Offer
  alias Wardrik.Chat.Replies
  alias Wardrik.Chat.Workspace

  @typedoc "What a room shows once its bot joins: its agent, agents to pick from, or none."
  @type shown() :: {:bound, Binding.t(), Offer.t()} | {:choose, [Offer.t()]} | :none

  @doc """
  Returns `room`'s binding, or `nil` if it has none.

  A workspace added again for another owner starts with no bindings.
  """
  @spec get(Workspace.t(), String.t()) :: Binding.t() | nil
  def get(%Workspace{installation: installation} = workspace, room) do
    owner = installation.owner

    store = store(workspace)

    case Wardrik.Store.get(store, key(workspace, room)) do
      %{"agent" => agent, "answers" => answers, "owner" => ^owner} ->
        %Binding{room: room, agent: agent, answers: answers(answers)}

      _unbound ->
        nil
    end
  end

  @doc "Binds `room` to the one agent offered. With several, returns them to choose from."
  @spec joined(Workspace.t(), String.t(), Member.t() | nil) :: shown()
  def joined(workspace, room, by \\ nil) do
    case Workspace.offered(workspace, by) do
      [offer] -> {:bound, bind(workspace, room, offer.agent, :mentions, by), offer}
      [] -> :none
      offers -> {:choose, offers}
    end
  end

  @doc "Returns the agents `by` may switch a room to, or `:none`."
  @spec choices(Workspace.t(), Member.t() | nil) :: {:choose, [Offer.t()]} | :none
  def choices(workspace, by \\ nil) do
    case Workspace.offered(workspace, by) do
      [] -> :none
      offers -> {:choose, offers}
    end
  end

  @doc """
  Binds `:room` to `:agent`, answering when mentioned. Returns `{:error, :not_offered}` if `:by`
  isn't offered it.

    * `:room` - the room. Required.
    * `:agent` - the agent's ID. Required.
    * `:by` - the `Wardrik.Chat.Member` who chose, or `nil` if the adapter doesn't know.
  """
  @spec chose(Workspace.t(), room: String.t(), agent: String.t(), by: Member.t() | nil) ::
          {:ok, Binding.t(), Offer.t()} | {:error, :not_offered}
  def chose(workspace, opts) do
    room = Keyword.fetch!(opts, :room)
    agent = Keyword.fetch!(opts, :agent)
    by = Keyword.get(opts, :by)

    offered = Workspace.offered(workspace, by)

    case Enum.find(offered, &(&1.agent == agent)) do
      %Offer{} = offer -> {:ok, bind(workspace, room, agent, :mentions, by), offer}
      nil -> {:error, :not_offered}
    end
  end

  @doc "Sets whether `room`'s agent answers `:mentions` or `:everything`."
  @spec answers(Workspace.t(), String.t(), Binding.answers(), Member.t() | nil) ::
          {:ok, Binding.t()} | {:error, :not_bound}
  def answers(workspace, room, answers, by \\ nil) when answers in [:mentions, :everything] do
    case get(workspace, room) do
      %Binding{agent: agent} -> {:ok, bind(workspace, room, agent, answers, by)}
      nil -> {:error, :not_bound}
    end
  end

  @doc "Unbinds `room`. Nothing more is posted in its threads."
  @spec left(Workspace.t(), String.t(), Member.t() | nil) :: :ok
  def left(workspace, room, by \\ nil) do
    case get(workspace, room) do
      %Binding{agent: agent} ->
        store = store(workspace)
        :ok = Wardrik.Store.delete(store, key(workspace, room))
        :ok = Replies.forget(workspace, room)
        record(workspace, by, "room.unbound", room, %{"agent" => %{"id" => agent}})

      nil ->
        :ok
    end
  end

  @doc """
  Returns whether `:room`'s agent has answered in `:thread`.

      Wardrik.Chat.Rooms.started?(workspace, room: "C024BE91L", thread: "1696.1234")
  """
  @spec started?(Workspace.t(), room: String.t(), thread: String.t()) :: boolean()
  def started?(workspace, opts) do
    store = store(workspace)
    Wardrik.Store.get(store, thread_key(workspace, opts)) != nil
  end

  @doc """
  Marks `:thread` as one `:room`'s agent answers in.

      :ok = Wardrik.Chat.Rooms.start(workspace, room: "C024BE91L", thread: "1696.1234")
  """
  @spec start(Workspace.t(), room: String.t(), thread: String.t()) :: :ok
  def start(workspace, opts) do
    store = store(workspace)
    {:ok, _vsn} = Wardrik.Store.put(store, thread_key(workspace, opts), true)
    :ok
  end

  defp bind(workspace, room, agent, answers, by) do
    bound = %{
      "agent" => agent,
      "answers" => Atom.to_string(answers),
      "owner" => workspace.installation.owner
    }

    store = store(workspace)
    {:ok, _vsn} = Wardrik.Store.put(store, key(workspace, room), bound)

    data = %{"agent" => %{"id" => agent}, "answers" => bound["answers"]}
    :ok = record(workspace, by, "room.bound", room, data)
    %Binding{room: room, agent: agent, answers: answers}
  end

  defp answers("mentions"), do: :mentions
  defp answers("everything"), do: :everything

  defp record(%Workspace{channel: channel} = workspace, by, type, room, data) do
    data = Map.merge(data, %{"channel" => channel.name, "room" => room})
    subject = "channels/#{channel.name}/rooms/#{room}"
    actor = actor(workspace, by)
    :ok = Wardrik.EventLog.record(channel.events, {type, subject, data}, actor: actor)
  end

  # Whoever your app knows the member as, else the channel acting for the installation's owner.
  defp actor(workspace, %Member{} = member) do
    case Workspace.identify(workspace, member) do
      {:ok, principal} -> principal
      {:error, _why} -> actor(workspace, nil)
    end
  end

  defp actor(workspace, nil), do: Workspace.scope(workspace).principal

  defp store(%Workspace{channel: channel}), do: channel.store

  defp key(workspace, room), do: "rooms/" <> place(workspace, room)

  defp thread_key(workspace, opts) do
    room = Keyword.fetch!(opts, :room)
    "threads/" <> place(workspace, room) <> "/" <> Keyword.fetch!(opts, :thread)
  end

  defp place(%Workspace{channel: channel, installation: installation}, room),
    do: Enum.join([channel.name, installation.workspace, room], "/")
end
