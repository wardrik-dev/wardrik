defmodule Tars.Agent do
  @moduledoc """
  Owns one agent's conversation and serializes turns against it.

  `ask/2` is non-blocking. Messages are queued in `pending` and drained one turn
  at a time: exactly one turn task runs at once, and this process is the only
  writer of `context`. Order is therefore a structural property rather than
  something callers have to coordinate.

  The turn itself runs in a `Task.Supervisor.async_nolink/3` task, so a failure
  inside `ReqLLM` or a tool cannot take the agent down.

  Stream and tool events do not pass through this process at all. The turn
  publishes them through its scope, and any number of listeners on any node can
  subscribe with `Tars.Event.Bus.subscribe/1`. See `TarsTUI.App` for a terminal
  one.

  A message arriving while a turn is running joins that turn rather than
  waiting for it: the turn is asked to stop at its next boundary, and the
  messages queued behind it start the next one against the context it left.
  Nothing in that path knows where the message came from.

  ## Durable and keyed

  An agent is a `DurableServer`: one process per key across the cluster, state
  written to the store on every change that matters, and restarted elsewhere
  when its node is lost. Start one with `Tars.Fleet.spawn/2`.

  Every function here takes a pid or a fleet key, and a key nothing holds
  answers `{:error, :not_found}`.

      Tars.Agent.ask("acme/jon/researcher", "What changed this week?")

  ## Interrupting

  `interrupt/1` asks the running turn to stop, drops everything queued behind
  it, and kills the turn if it has not returned within its grace. A tool
  already running does not read its mailbox, which is what the grace covers.
  Either way the agent settles idle and reports what it stopped as
  `{:turn_interrupted, stats}`.

  `Tars.Fleet.kill/1` does the same across a prefix.
  `Tars.LLM.ToolRunner.kill_call/2` stops one tool call rather than the turn.

  ## Waiting for a person

  A `Tars.Policy` that answers `{:ask, prompt}` parks the turn. The agent holds
  what it was doing, reports `:parked`, and does nothing until `resume/2`
  answers the calls it stopped on. Messages that arrive meanwhile queue behind
  it rather than starting a turn of their own, because the parked work is still
  the current work; `interrupt/1` abandons it if that is what you want.

  A parked turn is written to the store and outlives the node it parked on. A
  turn lost after being resumed comes back parked on the same calls. Resuming
  gives the turn this node's tools and a fresh budget.

  ## What a host supplies

  Beyond `:config`, an agent takes the seams every scope it roots is built
  with: `:policy` decides whether a tool call may run, `:dispatch` decides what
  a model call is and who pays for it, and `:timeout` bounds the whole turn.
  Each is optional and inert by default. Who the work is for is read from the
  agent's key.

  A config's tools are built on whichever node runs the agent. One that node
  cannot build is left out with a warning.

  The agent adds four events of its own so subscribers can follow its state
  without polling: `{:turn_started, questions}`, `{:turn_finished, messages}`,
  `{:turn_failed, reason}` and `{:turn_interrupted, stats}`. All are emitted on
  the turn's root span, so a subscriber can tell them from events the turn's
  own work produced. A client attaching mid-turn can catch up with `status/1`.
  """
  require Logger

  use DurableServer, vsn: 1

  alias ReqLLM.Context
  alias Tars.Agent.State
  alias Tars.Event
  alias Tars.Fleet
  alias Tars.LLM

  @typedoc "An agent: the pid of one, or the fleet key it is registered under."
  @type agent() :: pid() | String.t()

  @typedoc "Whether a turn is in flight, and how many messages are waiting behind it."
  @type status() :: State.status()

  @typedoc "What an interrupt stopped."
  @type stats() :: State.stats()

  @typedoc "Runs one turn and reports how it ended."
  @type runner() :: State.runner()

  @typedoc "Finishes a parked turn once its calls have been answered."
  @type resumer() :: State.resumer()

  # Transitions worth keeping sync on their own. This is the backstop.
  @sync_every_ms 30_000

  @doc """
  The state an agent starts life with, for `Tars.Fleet.spawn/2` to hand over.

  Options: `:config`, `:context`, `:runner`, `:resumer`, `:grace`, and the
  scope's `Tars.Scope.seams/0`.

  `:grace` is how long an interrupted turn is given to answer before it is
  killed, #{State.default_grace()}ms by default. `:runner` and `:resumer` are
  `{module, function, args}`; see `t:Tars.Agent.State.runner/0`.
  """
  @spec initial_state(keyword(), String.t()) :: State.t()
  def initial_state(opts, key), do: State.new(opts, key)

  @spec ask(agent(), String.t()) :: :ok | {:error, :not_found}
  def ask(agent, question), do: cast(agent, {:ask, question})

  @spec get_context(agent()) :: Context.t() | {:error, :not_found}
  def get_context(agent), do: call(agent, :get_context)

  @spec status(agent()) :: status() | {:error, :not_found}
  def status(agent), do: call(agent, :status)

  @doc """
  Stops whatever this agent is doing and discards whatever is queued.

  Non-blocking, and safe when the agent is idle. A parked turn is abandoned,
  which is the only way to get rid of one without answering it.
  """
  @spec interrupt(agent()) :: :ok | {:error, :not_found}
  def interrupt(agent), do: cast(agent, :interrupt)

  @doc """
  Answers the calls a parked turn stopped on and carries it on.

  `decisions` maps a tool call id to `:approve` or `{:deny, reason}`. Calls left
  out stay parked, so several people can answer one call each. Non-blocking,
  and a no-op when nothing is parked.

      Tars.Agent.resume("acme/jon/researcher", %{"call_abc" => :approve})
      Tars.Agent.resume(pid, %{"call_abc" => {:deny, "Not this quarter."}})
  """
  @spec resume(agent(), %{String.t() => LLM.Turn.Parked.decision()}) :: :ok | {:error, :not_found}
  def resume(agent, decisions) when is_map(decisions), do: cast(agent, {:resume, decisions})

  @doc """
  What this agent is waiting on, as `{call, prompt}` pairs, or `[]` when it is
  not parked.
  """
  @spec parked(agent()) :: [{Tars.Tool.call(), String.t()}] | {:error, :not_found}
  def parked(agent), do: call(agent, :parked)

  defp cast(agent, message) do
    case resolve(agent) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, message)
    end
  end

  defp call(agent, message) do
    case resolve(agent) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, message)
    end
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(key) when is_binary(key), do: Fleet.whereis(key)

  # -- durability ------------------------------------------------------------

  @impl DurableServer
  def dump_state(%State{} = state), do: State.dump(state)

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: State.load(dumped)

  @impl DurableServer
  def init(%State{} = state) do
    # `init` cannot return a continue, so the queue is drained by message.
    send(self(), :maybe_run)

    {:ok, state, meta: State.meta(state), permanent: true, sync_every_ms: @sync_every_ms}
  end

  # -- messages --------------------------------------------------------------

  @impl DurableServer
  def handle_call(:get_context, _from, state), do: {:reply, state.context, state}
  def handle_call(:status, _from, state), do: {:reply, State.status(state), state}
  def handle_call(:parked, _from, state), do: {:reply, State.waiting_on(state), state}

  @impl DurableServer
  def handle_cast({:ask, question}, state) do
    {state, effects} = State.queue(state, question)

    state |> perform(effects) |> advance(sync: true)
  end

  def handle_cast(:interrupt, state) do
    {state, effects} = State.interrupt(state)

    state |> perform(effects) |> advance(sync: true)
  end

  def handle_cast({:resume, decisions}, state) do
    case State.resume(state) do
      {:resume, scope, turn, started_at} ->
        task = run(fn -> State.apply_resumer(state, scope, turn, decisions) end)

        stay(State.resumed(state, task, scope, turn, started_at), sync: true)

      :none ->
        stay(state)
    end
  end

  @impl DurableServer
  def handle_continue(:maybe_run, state) do
    case State.take(state) do
      {:run, questions, state} -> stay(start(state, questions))
      :none -> stay(state)
    end
  end

  @impl DurableServer
  def handle_info(:maybe_run, state), do: advance(state)

  def handle_info({ref, result}, state) when is_reference(ref) do
    if State.running?(state, ref) do
      Process.demonitor(ref, [:flush])
      state |> answered(result) |> advance(sync: true)
    else
      stay(state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    if State.running?(state, ref) do
      Logger.error("Turn crashed: #{inspect(reason)}")
      state |> settle(State.failed(state, reason)) |> advance(sync: true)
    else
      stay(state)
    end
  end

  def handle_info({:kill, tag}, state) do
    case State.kill(state, tag) do
      {:kill, state, effects} -> state |> perform(effects) |> advance(sync: true)
      :stale -> stay(state)
    end
  end

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    stay(state)
  end

  # -- returns ---------------------------------------------------------------

  # Every return republishes this agent's metadata, which is what `Tars.Fleet`
  # lists. `sync: true` writes the state to the store before returning.
  defp advance(state, opts \\ []) do
    {:noreply, state, {:continue, :maybe_run}, [meta: State.meta(state)] ++ opts}
  end

  defp stay(state, opts \\ []) do
    {:noreply, state, [meta: State.meta(state)] ++ opts}
  end

  # -- turns -----------------------------------------------------------------

  defp start(state, questions) do
    context = Enum.reduce(questions, state.context, &LLM.Context.append_user_message(&2, &1))
    scope = State.turn_scope(state)

    Event.emit(scope.source, {:turn_started, questions})
    task = run(fn -> State.apply_runner(state, scope, context) end)

    State.started(state, task, scope, context, System.monotonic_time())
  end

  defp run(fun), do: Task.Supervisor.async_nolink(Tars.TaskSupervisor, fun)

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
