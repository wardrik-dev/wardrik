defmodule Tars.Agent do
  @moduledoc """
  Owns one agent's conversation and serializes turns against it.

  `ask/2` is non-blocking. Messages are queued in `pending` and drained one turn
  at a time: exactly one turn task runs at once, and this GenServer is the only
  writer of `context`. Order is therefore a structural property rather than
  something callers have to coordinate.

  The turn itself runs in a `Task.Supervisor.async_nolink/3` task, so a failure
  inside `ReqLLM` or a tool cannot take the agent down.

  Stream and tool events do not pass through this process at all. The turn
  publishes them through its scope, and any number of listeners can subscribe
  with `Tars.Event.Bus.subscribe/1`. See `TarsTUI.App` for a terminal one.

  A message arriving while a turn is running joins that turn rather than
  waiting for it: the turn is asked to stop at its next boundary, and the
  messages queued behind it start the next one against the context it left.
  Nothing in that path knows where the message came from.

  ## Interrupting

  `interrupt/1` is a kill switch, not a hint. It asks the running turn to stop,
  drops everything queued behind it, and if the turn has not returned within
  its grace — a tool already running does not read its mailbox — kills it.
  Either way the agent settles idle and reports what it stopped as
  `{:turn_interrupted, stats}`.

  It is an ordinary function, so an operator, a supervisor or another node can
  reach it without a terminal attached. To stop one tool call rather than the
  whole turn, see `Tars.LLM.ToolRunner.kill_call/2`.

  ## Waiting for a person

  A `Tars.Policy` that answers `{:ask, prompt}` parks the turn. The agent holds
  what it was doing, reports `:parked`, and does nothing until `resume/2`
  answers the calls it stopped on. Messages that arrive meanwhile queue behind
  it rather than starting a turn of their own, because the parked work is still
  the current work; `interrupt/1` abandons it if that is what you want.

  ## What a host supplies

  Beyond `:config`, an agent takes the seams every scope it roots is built
  with: `:user` and `:org` say who the work is for, `:policy` decides whether a
  tool call may run, `:dispatch` decides what a model call is and who pays for
  it, and `:timeout` bounds the whole turn. Each is optional and inert by
  default.

  The agent adds four events of its own so subscribers can follow its state
  without polling: `{:turn_started, questions}`, `{:turn_finished, messages}`,
  `{:turn_failed, reason}` and `{:turn_interrupted, stats}`. All are emitted on the turn's root span,
  so a subscriber can tell them from events the turn's own work produced. A
  client attaching mid-turn can catch up with `status/1`.
  """
  require Logger

  use GenServer

  alias ReqLLM.Context
  alias Tars.Agent.State
  alias Tars.Event
  alias Tars.LLM
  alias Tars.Scope

  @typedoc "Whether a turn is in flight, and how many messages are waiting behind it."
  @type status() :: State.status()

  @typedoc "What an interrupt stopped."
  @type stats() :: State.stats()

  @typedoc "Runs one turn and reports how it ended."
  @type runner() :: State.runner()

  @typedoc "Finishes a parked turn once its calls have been answered."
  @type resumer() :: State.resumer()

  @doc """
  Start an agent.

  Options: `:name`, `:config`, `:context`, `:runner`, `:resumer`, `:grace`, and
  the scope options `:user`, `:org`, `:policy`, `:dispatch` and `:timeout`.

  `:grace` is how long an interrupted turn is given to answer before it is
  killed, #{State.default_grace()}ms by default.

  The agent's event id is its `:name` when given, otherwise its pid. Subscribe
  to it with `Tars.Event.Bus.subscribe/1`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec ask(GenServer.server(), String.t()) :: :ok
  def ask(agent, question), do: GenServer.cast(agent, {:ask, question})

  @spec get_context(GenServer.server()) :: Context.t()
  def get_context(agent), do: GenServer.call(agent, :get_context)

  @spec status(GenServer.server()) :: status()
  def status(agent), do: GenServer.call(agent, :status)

  @doc """
  Stops whatever this agent is doing and discards whatever is queued.

  Non-blocking, and safe when the agent is idle. A parked turn is abandoned,
  which is the only way to get rid of one without answering it.
  """
  @spec interrupt(GenServer.server()) :: :ok
  def interrupt(agent), do: GenServer.cast(agent, :interrupt)

  @doc """
  Answers the calls a parked turn stopped on and carries it on.

  `decisions` maps a tool call id to `:approve` or `{:deny, reason}`. Calls left
  out stay parked, so several people can answer one call each. Non-blocking,
  and a no-op when nothing is parked.

      Tars.Agent.resume(:assistant, %{"call_abc" => :approve})
      Tars.Agent.resume(:assistant, %{"call_abc" => {:deny, "Not this quarter."}})
  """
  @spec resume(GenServer.server(), %{String.t() => LLM.Turn.Parked.decision()}) :: :ok
  def resume(agent, decisions) when is_map(decisions),
    do: GenServer.cast(agent, {:resume, decisions})

  @doc """
  What this agent is waiting on, as `{call, prompt}` pairs, or `[]` when it is
  not parked.
  """
  @spec parked(GenServer.server()) :: [{Tars.Tool.call(), String.t()}]
  def parked(agent), do: GenServer.call(agent, :parked)

  @impl true
  def init(opts) do
    {:ok, State.new(opts, Keyword.get(opts, :name) || self())}
  end

  @impl true
  def handle_call(:get_context, _from, state), do: {:reply, state.context, state}
  def handle_call(:status, _from, state), do: {:reply, State.status(state), state}
  def handle_call(:parked, _from, state), do: {:reply, State.waiting_on(state), state}

  @impl true
  def handle_cast({:ask, question}, state) do
    {state, effects} = State.queue(state, question)

    {:noreply, perform(state, effects), {:continue, :maybe_run}}
  end

  def handle_cast(:interrupt, state) do
    {state, effects} = State.interrupt(state)

    {:noreply, perform(state, effects), {:continue, :maybe_run}}
  end

  def handle_cast({:resume, decisions}, state) do
    case State.resume(state, decisions) do
      {:resume, scope, turn, started_at} ->
        task = run(fn -> state.resumer.(scope, turn, decisions) end)

        {:noreply, State.resumed(state, task, scope, started_at)}

      :none ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue(:maybe_run, state) do
    case State.take(state) do
      {:run, questions, state} -> {:noreply, start(state, questions)}
      :none -> {:noreply, state}
    end
  end

  defp start(state, questions) do
    context = Enum.reduce(questions, state.context, &LLM.Context.append_user_message(&2, &1))
    scope = Scope.root(state.config, state.agent_id, [name: "turn"] ++ state.scope_opts)

    Event.emit(scope.source, {:turn_started, questions})
    task = run(fn -> state.runner.(scope, context) end)

    State.started(state, task, scope, context, System.monotonic_time())
  end

  defp run(fun), do: Task.Supervisor.async_nolink(Tars.TaskSupervisor, fun)

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    if State.running?(state, ref) do
      Process.demonitor(ref, [:flush])
      {:noreply, answered(state, result), {:continue, :maybe_run}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    if State.running?(state, ref) do
      Logger.error("Turn crashed: #{inspect(reason)}")
      {:noreply, settle(state, State.failed(state, reason)), {:continue, :maybe_run}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:kill, tag}, state) do
    case State.kill(state, tag) do
      {:kill, state, effects} -> {:noreply, perform(state, effects), {:continue, :maybe_run}}
      :stale -> {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    {:noreply, state}
  end

  defp answered(state, {:ok, messages}), do: settle(state, State.settled(state, messages))
  defp answered(state, {:parked, turn}), do: settle(state, State.parked(state, turn))

  defp answered(state, {:error, reason}) do
    Logger.error("Turn failed: #{inspect(reason)}")
    settle(state, State.failed(state, reason))
  end

  defp settle(_state, {next, effects}), do: perform(next, effects)

  # The one place a state's decisions become things that happen. Each effect is
  # carried out in the order it was produced, and an effect that has something
  # to record hands the state back.
  defp perform(state, effects), do: Enum.reduce(effects, state, &apply_effect/2)

  defp apply_effect({:emit, source, payload}, state) do
    Event.emit(source, payload)
    state
  end

  defp apply_effect({:ask_to_stop, pid}, state) do
    LLM.Turn.yield(pid)
    state
  end

  defp apply_effect({:stop_now, pid}, state) do
    LLM.Turn.interrupt(pid)
    state
  end

  defp apply_effect({:arm_kill, ms, dropped}, state) do
    tag = make_ref()
    timer = Process.send_after(self(), {:kill, tag}, ms)

    State.arm(state, tag, timer, dropped)
  end

  defp apply_effect({:cancel_kill, timer}, state) do
    Process.cancel_timer(timer)
    state
  end

  defp apply_effect({:shutdown, task}, state) do
    Task.shutdown(task, :brutal_kill)
    state
  end
end
