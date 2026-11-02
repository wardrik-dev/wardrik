defmodule WardrikChannel.Replies.Server do
  @moduledoc """
  Posts in one room's threads.

  Follows the logs of every conversation in the room and posts what each event asks for. It saves
  its cursor after each post, so it carries on from there after a restart.

  A failed post is retried with backoff, up to a minute between tries. After eight attempts it's
  dropped with a warning. Later posts wait behind it. Statuses are shown at most once every two
  seconds per thread, and are never retried.
  """

  use DurableServer, vsn: 1

  require Logger

  alias WardrikChannel.Outbound
  alias WardrikChannel.Replies.Follower
  alias WardrikChannel.Replies.State
  alias WardrikChannel.Waiting
  alias WardrikChannel.Workspace

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
  def load_state(_vsn, dumped), do: State.load(dumped)

  @impl DurableServer
  def init(%State{} = state, %{channel: channel}) do
    Process.flag(:trap_exit, true)
    state = %{state | channel: channel}
    {:ok, follower} = WardrikEvents.Listener.start_link(Follower, follower(state))
    {:ok, %{state | follower: follower}}
  end

  @impl DurableServer
  def handle_call(:cursor, _from, state), do: {:reply, state.cursor, state}

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
  def terminate(_reason, %State{follower: follower}) when is_pid(follower) do
    Process.unlink(follower)
    Process.exit(follower, :kill)
  end

  def terminate(_reason, _state), do: :ok

  defp follower(state) do
    {:ok, workspace} = workspace(state)

    resources = [Workspace.logs(workspace, state.room)]
    events = state.channel.events

    [
      events: events,
      resources: resources,
      types: @types,
      started: WardrikEvents.head(events, resources),
      server: self()
    ]
  end

  defp posting(state, {event, cursor, from} = held, attempt) do
    conversation = conversation(event)
    {post, next} = State.take(state, conversation, event)

    case post(next, conversation, post) do
      :ok ->
        posted(shown(next, conversation, post), cursor, from)

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

  defp conversation(%Wardrik.Event{source: source}) do
    [_deployment, id] = String.split(source, "/agents/", parts: 2)
    id
  end

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

  defp waiting(state, conversation, ids, asked_by) do
    with {:ok, workspace} <- workspace(state),
         {:ok, agent} <- Wardrik.Agent.read(Workspace.scope(workspace), conversation) do
      for interrupt <- agent.interrupts,
          ids == :all or interrupt.id in ids,
          do: %Waiting{
            conversation: conversation,
            interrupt: interrupt,
            arguments:
              State.arguments(state, conversation: conversation, call: interrupt.tool_call_id),
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

  defp deliver(state, conversation, body) do
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
