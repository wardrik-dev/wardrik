defmodule WardrikCore.Agent do
  @moduledoc false
  use DurableServer, vsn: 1

  alias WardrikCore.Agent.State
  alias WardrikCore.Event
  alias WardrikCore.Resume
  alias WardrikCore.Span
  alias WardrikCore.Turn

  require Logger

  @impl DurableServer
  def dump_state(%State{} = state), do: State.dump(state)

  @impl DurableServer
  def load_state(_vsn, state), do: State.load(state)

  @impl DurableServer
  def init(%State{} = state) do
    Logger.info("Initializing agent #{state.agent_id}")

    Process.flag(:trap_exit, true)

    # DurableServer's init can't return a continue, so drain the queue by message.
    # credo:disable-for-next-line WardrikCore.Credo.Check.NoSelfSend
    send(self(), :maybe_run)

    emit(state, [:agent, :start], %{system_time: System.system_time()}, %{state: state.state})
    {:ok, state, permanent: true}
  end

  @impl true
  def handle_call({:ask, text, metadata}, _from, %State{} = state) do
    if state.state == :running, do: Turn.yield(state.task.pid)

    metadata =
      metadata
      |> Map.put_new_lazy(:id, &message_id/0)
      |> Map.put_new_lazy(:sent_at, fn -> DateTime.truncate(DateTime.utc_now(), :second) end)

    message = ReqLLM.Context.user(text, metadata)
    state = State.queue(state, message)

    emit(state, [:message, :queued], %{queued: length(state.pending_messages)}, %{
      message: message
    })

    {:reply, :ok, state, {:continue, :maybe_run}, sync: true}
  end

  def handle_call({:configure, opts}, _from, state),
    do: {:reply, :ok, State.configure(state, opts), sync: true}

  def handle_call(:history, _from, state), do: {:reply, state.messages, state}

  def handle_call(:context, _from, state),
    do: {:reply, %{state.context | model: state.model, messages: state.messages}, state}

  def handle_call(:status, _from, state), do: {:reply, state.state, state}
  def handle_call(:stop, _from, state), do: {:stop, :permanent, :ok, state}

  def handle_call({:resume, input, metadata}, _from, %State{state: :waiting} = state),
    do: {:reply, :ok, resumed(state, input, metadata)}

  def handle_call({:resume, input, metadata}, _from, %State{state: :running} = state) do
    if answerable?(state, input),
      do: {:reply, :ok, State.answer_later(state, input, metadata)},
      else: {:reply, {:error, :not_parked}, state}
  end

  def handle_call({:resume, _input, _metadata}, _from, state),
    do: {:reply, {:error, :not_parked}, state}

  def handle_call(:parked, _from, state), do: {:reply, State.waiting(state), state}

  def handle_call({:checkpoint, checkpoint}, {pid, _tag}, %State{task: %Task{pid: pid}} = state) do
    emit(state, [:turn, :checkpoint], %{calls: length(checkpoint.calls)}, %{})
    {:reply, :ok, State.checkpointed(state, checkpoint), sync: true}
  end

  def handle_call({:checkpoint, _checkpoint}, _from, state), do: {:reply, :stale, state}

  def handle_call(:interrupt, _from, %State{state: :running} = state),
    do: {:reply, :ok, stop_running(state, :interrupted), {:continue, :maybe_run}, sync: true}

  def handle_call(:interrupt, _from, %State{state: :waiting} = state) do
    stop_turn(state, %{outcome: :interrupted, kept: length(state.in_flight), dropped: 0})
    {:reply, :ok, State.unanswered(state), {:continue, :maybe_run}, sync: true}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, :idle}, state}

  def handle_call({:kill, call_id}, _from, %State{calls: calls} = state) do
    case Map.fetch(calls, call_id) do
      {:ok, pid} -> {:reply, kill_call(pid), state}
      :error -> {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_cast(request, state) do
    Logger.warning("Agent #{state.agent_id} ignored an unknown cast: #{inspect(request)}")
    {:noreply, state}
  end

  @impl true
  def handle_continue(:maybe_run, %State{state: :due, checkpoint: checkpoint} = state) do
    context = turn_context(state, checkpoint.messages, checkpoint.span)
    {:noreply, start_turn(state, :recover, context, fn -> Turn.recover(context, checkpoint) end)}
  end

  def handle_continue(:maybe_run, %State{state: :idle, pending_messages: [_ | _]} = state) do
    {batch, state} = State.take_batch(state)
    context = turn_context(state, state.messages ++ batch, Span.root())
    started = %{message_ids: for(%{metadata: %{id: id}} <- batch, do: id)}
    {:noreply, start_turn(state, :run, context, started, fn -> Turn.run(context) end)}
  end

  def handle_continue(
        :maybe_run,
        %State{state: :waiting, answers: [{input, metadata} | rest]} = state
      ) do
    state = %{state | answers: rest}

    if answerable?(state, input),
      do: {:noreply, resumed(state, input, metadata), {:continue, :maybe_run}},
      else: {:noreply, state, {:continue, :maybe_run}}
  end

  def handle_continue(:maybe_run, state), do: {:noreply, state}

  @impl true
  def handle_info(:maybe_run, state), do: {:noreply, state, {:continue, :maybe_run}}

  def handle_info({ref, result}, %State{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result), {:continue, :maybe_run}, sync: true}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{task: %Task{ref: ref}} = state) do
    Logger.error("Turn crashed for agent #{state.agent_id}: #{inspect(reason)}")
    stop_turn(state, %{outcome: :crash})
    {:noreply, State.unanswered(state), {:continue, :maybe_run}, sync: true}
  end

  def handle_info({:turn_timeout, ref}, %State{task: %Task{ref: ref}} = state),
    do: {:noreply, stop_running(state, :timeout), {:continue, :maybe_run}, sync: true}

  def handle_info({:turn_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({:call_started, call_id, pid}, %State{state: :running} = state),
    do: {:noreply, %{state | calls: Map.put(state.calls, call_id, pid)}}

  def handle_info({:call_started, _call_id, _pid}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    emit(state, [:agent, :stop], %{}, %{reason: reason})
  end

  defp resumed(state, input, metadata) do
    parked = state.parked
    resume = %Resume{reason: parked.reason, input: input, metadata: metadata}

    context = %{
      turn_context(state, parked.messages, parked.span)
      | metadata: Map.merge(state.context.metadata, parked.metadata),
        measurements: parked.measurements
    }

    state
    |> start_turn(:resume, context, %{metadata: metadata}, fn -> Turn.resume(context, resume) end)
    |> State.answered(input)
  end

  defp answerable?(state, input) when is_map(input) and map_size(input) > 0 do
    case State.waiting(state) do
      {:tool_calls, waiting} ->
        ids = for {call, _outcome} <- waiting, do: call.id
        Enum.all?(Map.keys(input), &(&1 in ids))

      _other ->
        false
    end
  end

  defp answerable?(_state, _input), do: false

  defp turn_context(state, messages, span) do
    agent = self()

    %{
      state.context
      | model: state.model,
        messages: messages,
        span: span,
        checkpoint: fn checkpoint ->
          GenServer.call(agent, {:checkpoint, checkpoint}, :timer.seconds(30))
        end,
        call_started: fn call_id ->
          send(agent, {:call_started, call_id, self()})
          :ok
        end
    }
  end

  defp start_turn(state, kind, context, started \\ %{}, fun) do
    started = Map.merge(started, %{span: context.span, kind: kind})
    emit(state, [:turn, :start], %{system_time: System.system_time()}, started)

    task = Task.async(fun)
    arm_timeout(state.context.timeout, task)
    State.running(state, task, kind, context.span)
  end

  defp kill_call(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
      :ok
    else
      {:error, :not_running}
    end
  end

  defp arm_timeout(:infinity, _task), do: :ok
  defp arm_timeout(ms, task), do: Process.send_after(self(), {:turn_timeout, task.ref}, ms)

  defp stop_running(state, outcome) do
    case Task.shutdown(state.task, :brutal_kill) do
      {:ok, result} ->
        finish(state, result)

      _stopped ->
        stop_turn(state, %{outcome: outcome, kept: length(state.in_flight), dropped: 0})
        State.unanswered(state)
    end
  end

  defp finish(state, result) do
    stop_turn(state, ended(result))
    log_ended(state, result)
    State.finished(state, result)
  end

  defp ended({:park, reason, _context}), do: %{outcome: :park, reason: reason}
  defp ended({:ok, context}), do: %{outcome: :ok, messages: answer(context.messages)}
  defp ended({:error, reason}), do: %{outcome: :error, reason: reason}
  defp ended(result), do: %{outcome: elem(result, 0)}

  defp answer(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(fn message -> message.role != :user end)
    |> Enum.reverse()
  end

  defp message_id,
    do: "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp log_ended(state, {:park, reason, _context}),
    do: Logger.info("Turn parked for agent #{state.agent_id}: #{inspect(reason)}")

  defp log_ended(state, {:error, reason}),
    do: Logger.error("Turn failed for agent #{state.agent_id}: #{inspect(reason)}")

  defp log_ended(_state, {:ok, _context}), do: :ok

  defp stop_turn(state, ended) do
    measured = %{duration: System.monotonic_time() - state.started_at}

    emit(
      state,
      [:turn, :stop],
      measured,
      Map.merge(%{span: state.span, kind: state.turn_kind}, ended)
    )
  end

  defp emit(state, event, measurements, metadata) do
    metadata = Map.merge(metadata, %{agent_id: state.agent_id, conversation: state.conversation})
    Event.emit(state.context, [:wardrik_core | event], measurements, metadata)
  end
end
