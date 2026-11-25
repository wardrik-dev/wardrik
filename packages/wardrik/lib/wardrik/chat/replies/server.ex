defmodule Wardrik.Chat.Replies.Server do
  @moduledoc false

  use DurableServer, vsn: 3

  alias Wardrik.Chat.Outbound
  alias Wardrik.Chat.Replies.Follower
  alias Wardrik.Chat.Replies.State
  alias Wardrik.Chat.Step
  alias Wardrik.Chat.Waiting
  alias Wardrik.Chat.Workspace
  alias Wardrik.EventLog.Cursor

  require Logger

  @types ~w(wardrik.message.created wardrik.run.started wardrik.run.resumed
            wardrik.message.started wardrik.message.delta wardrik.reasoning.delta
            wardrik.message.retrying wardrik.message.completed
            wardrik.tool_call.started wardrik.tool_call.retrying wardrik.tool_call.completed
            wardrik.subagent.started wardrik.subagent.progress wardrik.subagent.completed
            wardrik.subagent.failed
            wardrik.run.completed wardrik.run.interrupted wardrik.run.failed wardrik.run.cancelled
            wardrik.run.deadline_exceeded wardrik.interrupt.resolved)

  @first_backoff 1_000
  @max_backoff 60_000
  @attempts 8
  @throttle 2_000
  @beat 15_000

  @impl DurableServer
  def dump_state(state), do: State.dump(state)

  # A room's first state is loaded with no version.
  @impl DurableServer
  def load_state(nil, dumped), do: State.load(3, dumped)
  def load_state(vsn, dumped), do: State.load(vsn, dumped)

  @impl DurableServer
  def init(%State{} = state, %{channel: channel}) do
    Process.flag(:trap_exit, true)
    state = listen(%{state | channel: channel})
    running = Map.keys(state.runs)
    {:ok, Enum.reduce(running, state, &schedule_beat(&2, &1))}
  end

  @impl DurableServer
  def handle_call(:cursor, _from, state), do: {:reply, state.cursor, state}

  def handle_call({:follow, conversation, {message, asker}}, _from, state) do
    state = State.put_asker(state, message, asker)

    if conversation in state.conversations,
      do: {:reply, :ok, state, sync: true},
      else: {:reply, :ok, follow(state, conversation), sync: true}
  end

  def handle_call({:event, event, cursor}, from, state),
    do: posting(state, {event, cursor, from}, 1)

  @impl DurableServer
  def handle_cast({:remind, conversation}, state) do
    post = {:waiting, :all, State.find_asker(state, conversation)}

    with {:error, reason} <- post(state, state, conversation, post) do
      Logger.warning("#{state.channel.name} couldn't remind #{state.room}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl DurableServer
  def handle_info({:retry, held, attempt}, state), do: posting(state, held, attempt)

  def handle_info({:beat, conversation}, state) do
    {:ok, posted} = post_progress(state, conversation)
    {:noreply, posted, sync: progress(posted, conversation) != progress(state, conversation)}
  end

  def handle_info({:EXIT, follower, reason}, %State{follower: follower} = state),
    do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl DurableServer
  def terminate(_reason, state), do: stop(state.follower)

  # Reads the new conversation from its end now, then follows it with the rest.
  defp follow(state, conversation) do
    {:ok, read} = Cursor.decode(state.cursor || Cursor.encode(%{}))

    {:ok, head} =
      state.channel.events
      |> Wardrik.EventLog.head([conversation])
      |> Cursor.decode()

    cursor =
      head
      |> Map.merge(read)
      |> Cursor.encode()

    listen(%{state | conversations: state.conversations ++ [conversation], cursor: cursor})
  end

  defp listen(%State{conversations: []} = state), do: state

  defp listen(state) do
    :ok = stop(state.follower)

    {:ok, follower} =
      Wardrik.EventLog.Follower.start_link(Follower, %{cursor: nil, options: [server: self()]},
        events: state.channel.events,
        logs: state.conversations,
        types: @types
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

    case post(state, next, conversation, post) do
      {:ok, posted} ->
        handle_posted(posted, cursor, from)

      {:error, reason} when attempt >= @attempts ->
        Logger.warning(
          "#{state.channel.name} gave up posting in #{state.room}: #{inspect(reason)}"
        )

        handle_posted(next, cursor, from)

      {:error, _reason} ->
        Process.send_after(self(), {:retry, held, attempt + 1}, backoff(attempt))
        {:noreply, state}
    end
  end

  # Live events, such as a model's text as it streams, leave the cursor where it was.
  defp handle_posted(state, cursor, from) do
    GenServer.reply(from, :ok)
    {:noreply, %{state | cursor: cursor}, sync: cursor != state.cursor}
  end

  defp backoff(attempt), do: min(@first_backoff * Integer.pow(2, attempt - 1), @max_backoff)

  defp conversation(%Wardrik.Event{agent: agent, conversation: conversation}),
    do: {agent, conversation}

  # `before` is the state before the event, which holds the run a reply or failure ends.
  defp post(_before, state, _conversation, :none), do: {:ok, state}

  defp post(_before, state, conversation, {:progress, :changed}),
    do: post_progress(state, conversation)

  defp post(_before, state, conversation, {:progress, :details}) do
    if due?(state, conversation),
      do: post_progress(state, conversation),
      else: {:ok, state}
  end

  defp post(before, state, conversation, {:stopped, _answering} = body) do
    _posted = post_ending(before, state, conversation, body, :failed)
    {:ok, end_progress(state, conversation)}
  end

  defp post(before, state, conversation, {:waiting, ids, asked_by}) do
    case waiting(state, conversation, ids, asked_by) do
      [] -> {:ok, state}
      calls -> post_ending(before, state, conversation, {:waiting, calls}, :waiting)
    end
  end

  defp post(before, state, conversation, {:reply, _text, _answering} = body),
    do: post_ending(before, state, conversation, body, :done)

  defp post(before, state, conversation, {:failed, _reason} = body),
    do: post_ending(before, state, conversation, body, :failed)

  defp post(_before, state, conversation, {:said, _text} = body) do
    case deliver(state, conversation, body, nil) do
      {:error, reason} -> {:error, reason}
      _posted -> {:ok, state}
    end
  end

  # A step still running when its run ends is shown ended as `status`, then the run's last post.
  defp post_ending(before, state, conversation, body, status) do
    run = State.find_run(before, conversation)
    :ok = end_running_steps(state, conversation, run, status)

    case deliver(state, conversation, body, run) do
      {:error, reason} -> {:error, reason}
      _posted -> {:ok, end_progress(state, conversation)}
    end
  end

  defp post_progress(state, conversation) do
    case State.find_run(state, conversation) do
      %{steps: [_ | _] = steps} = run ->
        state
        |> deliver(conversation, {:progress, steps}, run)
        |> note_progress(state, conversation)
        |> schedule_beat(conversation)
        |> then(&{:ok, &1})

      _no_steps ->
        {:ok, state}
    end
  end

  defp note_progress({:ok, progress}, state, conversation),
    do:
      state
      |> State.put_progress(conversation, progress)
      |> mark_shown(conversation)

  defp note_progress(:ok, state, conversation), do: mark_shown(state, conversation)
  defp note_progress({:skip, _why}, state, _conversation), do: state

  # Progress is shown as it was, and the next post brings it up to date.
  defp note_progress({:error, reason}, state, _conversation) do
    Logger.debug(
      "#{state.channel.name} couldn't post progress in #{state.room}: #{inspect(reason)}"
    )

    state
  end

  defp end_running_steps(state, conversation, %{progress: progress, steps: steps} = run, status)
       when is_binary(progress) do
    if Enum.any?(steps, &(&1.status == :running)) do
      ended = Enum.map(steps, &end_running_step(&1, status))
      _shown = deliver(state, conversation, {:progress, ended}, run)
    end

    :ok
  end

  defp end_running_steps(_state, _conversation, _run, _status), do: :ok

  defp end_running_step(%Step{status: :running} = step, status), do: %{step | status: status}
  defp end_running_step(step, _status), do: step

  defp end_progress(state, conversation) do
    cancel_beat(state, conversation)

    %{
      state
      | shown: Map.delete(state.shown, conversation),
        beats: Map.delete(state.beats, conversation)
    }
  end

  defp schedule_beat(state, conversation) do
    cancel_beat(state, conversation)

    if State.running?(state, conversation) do
      beat = Process.send_after(self(), {:beat, conversation}, @beat)
      put_in(state.beats[conversation], beat)
    else
      %{state | beats: Map.delete(state.beats, conversation)}
    end
  end

  defp cancel_beat(state, conversation) do
    with {:ok, beat} <- Map.fetch(state.beats, conversation), do: Process.cancel_timer(beat)
    :ok
  end

  defp progress(state, conversation), do: get_in(state.runs, [conversation, :progress])

  defp waiting(state, {agent, id}, ids, asked_by) do
    with {:ok, workspace} <- workspace(state),
         scope = Workspace.scope(workspace),
         {:ok, read} <- Wardrik.Agent.read(scope, agent, conversation: id) do
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

  defp mark_shown(state, conversation),
    do: put_in(state.shown[conversation], System.monotonic_time(:millisecond))

  defp deliver(state, {_agent, conversation}, body, run) do
    case workspace(state) do
      {:ok, %Workspace{channel: channel, installation: installation} = workspace} ->
        outbound = %Outbound{
          installation: installation,
          room: state.room,
          thread: Workspace.thread(workspace, room: state.room, conversation: conversation),
          body: body,
          progress: run[:progress],
          asker: run[:asker]
        }

        channel.adapter.deliver(outbound, channel)

      :error ->
        :ok
    end
  end

  defp workspace(%State{channel: channel, workspace: id}), do: Workspace.new(channel, id)
end
