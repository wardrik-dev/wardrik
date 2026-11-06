defmodule WardrikChannel.Replies.Server do
  @moduledoc false

  use DurableServer, vsn: 2

  require Logger

  alias WardrikChannel.Outbound
  alias WardrikChannel.Replies.Follower
  alias WardrikChannel.Replies.State
  alias WardrikChannel.Waiting
  alias WardrikChannel.Workspace
  alias WardrikEvents.Cursor

  @types ~w(wardrik.message.created wardrik.run.started wardrik.tool_call.started
            wardrik.run.completed wardrik.run.interrupted wardrik.run.failed wardrik.run.cancelled
            wardrik.interrupt.resolved)

  @first_backoff 1_000
  @max_backoff 60_000
  @attempts 8
  @throttle 2_000

  @impl DurableServer
  def dump_state(state), do: State.dump(state)

  @impl DurableServer
  # Before 2, the room followed every log by a pattern, with a cursor of its own shape.
  def load_state(1, %{workspace: workspace, room: room}), do: State.new(workspace, room)
  def load_state(_vsn, dumped), do: State.load(dumped)

  @impl DurableServer
  def init(%State{} = state, %{channel: channel}) do
    Process.flag(:trap_exit, true)
    {:ok, listen(%{state | channel: channel})}
  end

  @impl DurableServer
  def handle_call(:cursor, _from, state), do: {:reply, state.cursor, state}

  def handle_call({:follow, conversation}, _from, state) do
    if conversation in state.conversations,
      do: {:reply, :ok, state},
      else: {:reply, :ok, followed(state, conversation), sync: true}
  end

  def handle_call({:event, event, cursor}, from, state),
    do: posting(state, {event, cursor, from}, 1)

  @impl DurableServer
  def handle_cast({:remind, conversation}, state) do
    post = {:waiting, :all, State.asked_by(state, conversation)}

    with {:error, reason} <- post(state, conversation, post) do
      Logger.warning("#{state.channel.name} couldn't remind #{state.room}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl DurableServer
  def handle_info({:retry, held, attempt}, state), do: posting(state, held, attempt)

  def handle_info({:EXIT, follower, reason}, %State{follower: follower} = state),
    do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl DurableServer
  def terminate(_reason, state), do: stop(state.follower)

  # Reads the new conversation from its end now, then follows it with the rest.
  defp followed(state, conversation) do
    {:ok, read} = Cursor.decode(state.cursor || Cursor.encode(%{}))
    {:ok, head} = Cursor.decode(WardrikEvents.head(state.channel.events, [conversation]))

    listen(%{
      state
      | conversations: state.conversations ++ [conversation],
        cursor: Cursor.encode(Map.merge(head, read))
    })
  end

  defp listen(%State{conversations: []} = state), do: state

  defp listen(state) do
    :ok = stop(state.follower)

    {:ok, follower} =
      WardrikEvents.Listener.start_link(Follower,
        events: state.channel.events,
        resources: state.conversations,
        types: @types,
        server: self()
      )

    %{state | follower: follower}
  end

  defp stop(follower) when is_pid(follower) do
    Process.unlink(follower)
    Process.exit(follower, :kill)
    :ok
  end

  defp stop(nil), do: :ok

  # An event from a follower since replaced is read again by the new one.
  defp posting(
         %State{follower: follower} = state,
         {_event, _cursor, {pid, _tag} = from},
         _attempt
       )
       when pid != follower do
    GenServer.reply(from, :ok)
    {:noreply, state}
  end

  defp posting(state, {event, cursor, from} = held, attempt) do
    conversation = conversation(event)
    {post, next} = State.take(state, conversation, event)

    case post(next, conversation, post) do
      :ok ->
        posted(shown(next, conversation, post), cursor, from)

      {:skip, _why} ->
        posted(next, cursor, from)

      {:error, reason} when attempt >= @attempts ->
        Logger.warning(
          "#{state.channel.name} gave up posting in #{state.room}: #{inspect(reason)}"
        )

        posted(next, cursor, from)

      {:error, _reason} ->
        Process.send_after(self(), {:retry, held, attempt + 1}, backoff(attempt))
        {:noreply, state}
    end
  end

  defp posted(state, cursor, from) do
    GenServer.reply(from, :ok)
    {:noreply, %{state | cursor: cursor}, sync: true}
  end

  defp backoff(attempt), do: min(@first_backoff * Integer.pow(2, attempt - 1), @max_backoff)

  defp conversation(%Wardrik.Event{agent: agent, conversation: conversation}),
    do: {agent, conversation}

  defp post(_state, _conversation, :none), do: :ok

  defp post(state, conversation, {:status, label}) do
    if due?(state, conversation), do: deliver(state, conversation, {:status, label})
    :ok
  end

  defp post(state, conversation, {:stopped, answering}) do
    _cleared = deliver(state, conversation, {:stopped, answering})
    :ok
  end

  defp post(state, conversation, {:waiting, ids, asked_by}) do
    case waiting(state, conversation, ids, asked_by) do
      [] -> :ok
      calls -> deliver(state, conversation, {:waiting, calls})
    end
  end

  defp post(state, conversation, body), do: deliver(state, conversation, body)

  defp waiting(state, {agent, id}, ids, asked_by) do
    with {:ok, workspace} <- workspace(state),
         {:ok, read} <- Wardrik.Agent.read(Workspace.scope(workspace), agent, conversation: id) do
      for interrupt <- read.interrupts,
          ids == :all or interrupt.id in ids,
          do: %Waiting{
            agent: agent,
            conversation: id,
            interrupt: interrupt,
            arguments: interrupt.arguments,
            asked_by: asked_by
          }
    else
      _gone -> []
    end
  end

  defp due?(state, conversation) do
    case Map.fetch(state.shown, conversation) do
      {:ok, at} -> System.monotonic_time(:millisecond) - at >= @throttle
      :error -> true
    end
  end

  defp shown(state, conversation, {:status, _label}) do
    if due?(state, conversation),
      do: put_in(state.shown[conversation], System.monotonic_time(:millisecond)),
      else: state
  end

  defp shown(state, conversation, _posted),
    do: %{state | shown: Map.delete(state.shown, conversation)}

  defp deliver(state, {_agent, conversation}, body) do
    case workspace(state) do
      {:ok, %Workspace{channel: channel, installation: installation} = workspace} ->
        outbound = %Outbound{
          installation: installation,
          room: state.room,
          thread: Workspace.thread(workspace, room: state.room, conversation: conversation),
          body: body
        }

        channel.adapter.deliver(outbound, channel)

      :error ->
        :ok
    end
  end

  defp workspace(%State{channel: channel, workspace: id}), do: Workspace.new(channel, id)
end
