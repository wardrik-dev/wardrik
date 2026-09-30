defmodule Wardrik.Agent do
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
  subscribe with `Wardrik.Event.Bus.subscribe/1`. See `WardrikConsole` for one
  that prints to a terminal.

  A message arriving while a turn is running joins that turn rather than
  waiting for it: the turn is asked to stop at its next boundary, and the
  messages queued behind it start the next one against the context it left.
  Nothing in that path knows where the message came from.

  ## Durable and keyed

  An agent is a `DurableServer`: one process per key across the cluster, state
  written to the store on every change that matters, and restarted elsewhere
  when its node is lost. Start one with `Wardrik.Fleet.spawn/2`.

  Every function here takes a pid or a fleet key, and a key nothing holds
  answers `{:error, :not_found}`.

      Wardrik.Agent.ask("acme/jon/researcher", "What changed this week?")

  ## Interrupting

  `interrupt/1` asks the running turn to stop, drops everything queued behind
  it, and kills the turn if it has not returned within its grace. A tool
  already running does not read its mailbox, which is what the grace covers.
  Either way the agent settles idle and reports what it stopped as
  `{:turn_interrupted, stats}`.

  `Wardrik.Fleet.kill/1` does the same across a prefix.
  `Wardrik.LLM.ToolRunner.kill_call/2` stops one tool call rather than the turn.

  ## Waiting for a person

  A `Wardrik.Hook` that asks a person about a call parks the turn. The agent holds
  what it was doing, reports `:parked`, and does nothing until `resume/2`
  answers the calls it stopped on, and emits `{:call_decided, call_id, decision,
  by}` for each, with the `Wardrik.Principal` a caller names as `:by`. Messages
  that arrive meanwhile queue behind
  it rather than starting a turn of their own, because the parked work is still
  the current work; `interrupt/1` abandons it if that is what you want.

  A parked turn is written to the store and outlives the node it parked on. A
  turn lost after being resumed comes back parked on the same calls. Resuming
  gives the turn this node's tools and a fresh budget.

  ## A history that grows

  Before a turn, an agent whose history has outgrown its config's
  `Wardrik.Compaction` summarises the older part first, with its own model, and
  reports `{:context_compacted, stats}`. Messages arriving meanwhile queue for
  the turn that follows. A summary that cannot be made leaves the history as it
  was, and the turn runs regardless.

  ## A turn lost part way

  Each turn hands the agent every batch of tool calls before running it, and
  the agent writes the batch to the store before the calls run. A turn lost
  after that comes back replaying from its last batch, with the same calls, and
  a `Wardrik.Ledger` on the scope answers for any that already ran. See
  `Wardrik.LLM.Turn`.

  A turn is tethered to its agent, and each tool call to its turn, so an agent
  that stops or moves leaves nothing of its turn running beside the replay.
  Once a turn has ended for good, finished, failed or abandoned, the ledger
  forgets its calls.

  ## What a host supplies

  Beyond `:config`, an agent takes the seams every scope it roots is built
  with: `:hooks` decide whether a tool call may run and a model call be made,
  `:dispatch` decides what a model call is and who pays for it, and `:timeout`
  bounds the whole turn. Each is optional and inert by default. Who the work is
  for is read from the agent's key.

  A config's tools are built on whichever node runs the agent. One that node
  cannot build is left out with a warning.

  The agent adds events of its own so subscribers can follow its state
  without polling: `{:turn_started, messages}`, `{:turn_finished, messages}`,
  `{:turn_failed, reason}`, `{:turn_interrupted, stats}`,
  `{:turn_resumed, decisions}` and `{:call_decided, call_id, decision, by}`
  on the turn's root span, so a subscriber can tell them from events the
  turn's own work produced; and `{:message_queued, message}` as a message
  arrives and `{:agent_started, node, status, generation}` each time the agent is loaded,
  on the root of a trace of their own. A client attaching mid-turn can catch
  up with `status/1` or `snapshot/1`.

  ## Delegations

  The agent follows its own events, so it knows which delegations the current
  turn has started through `Wardrik.Subagent.run/3` and how each went. The fleet
  shows the count as part of the agent's metadata, and `snapshot/1` carries
  the whole `Wardrik.Delegation` for a client that wants to list or inspect them.

  ## Its log

  The agent is the only writer of its `Wardrik.Event.Log`. It numbers its events
  in the order they reach it, writes the durable ones, and passes every one on
  to the log's subscribers; see `Wardrik.Event.Log.Writer`. A turn never waits
  for it.

  A decision is written before it takes effect: `decide/3` answers
  `{:error, :unrecorded}`, and changes nothing, when it cannot be. After each
  turn the agent drops the events older than the log keeps.
  """
  require Logger

  use DurableServer, vsn: 1

  alias ReqLLM.Context
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.Agent.State
  alias Wardrik.Event
  alias Wardrik.Event.Bus
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Event.Source
  alias Wardrik.Fleet
  alias Wardrik.LLM.Turn

  @typedoc "An agent: the pid of one, or the fleet key it is registered under."
  @type agent() :: pid() | String.t()

  @typedoc "Whether a turn is in flight, how many messages wait behind it, and the model."
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
  The state an agent starts life with, for `Wardrik.Fleet.spawn/2` to hand over.

  Options: `:config`, `:context`, `:runner`, `:resumer`, `:grace`, and the
  scope's `Wardrik.Scope.seams/0`.

  `:grace` is how long an interrupted turn is given to answer before it is
  killed, #{State.default_grace()}ms by default. `:runner` and `:resumer` are
  `{module, function, args}`; see `t:Wardrik.Agent.State.runner/0`.
  """
  @spec initial_state(keyword(), String.t()) :: State.t()
  def initial_state(opts, key), do: State.new(opts, key)

  @doc """
  Gives the agent a new `:config` and new seams for the turns it starts from
  now on, and writes them to the store. See `Wardrik.Agent.State.configure/2`.

  An agent waiting on a person under hooks other than the ones it is given is
  resumed with no decisions, so its new hooks decide the calls it waits on:
  each goes ahead, is refused, or waits again on what the new hooks ask.

      Wardrik.Agent.configure("acme/jon/researcher", config: config, hooks: hooks)
  """
  @spec configure(agent(), keyword()) :: :ok | {:error, :not_found}
  def configure(agent, opts) when is_list(opts), do: call(agent, {:configure, opts})

  @doc """
  Queues a message for the agent to answer.

  `:id` names the message, a new UUIDv7 when left out. The agent announces it
  as `{:message_queued, message}` and takes it once, however many times the
  same id is sent.
  """
  @spec ask(agent(), String.t(), keyword()) :: :ok | {:error, :not_found}
  def ask(agent, question, opts \\ []) when is_binary(question) and is_list(opts),
    do: cast(agent, {:ask, Message.new(question, Keyword.get(opts, :id))})

  @spec get_context(agent()) :: Context.t() | {:error, :not_found}
  def get_context(agent), do: call(agent, :get_context)

  @spec status(agent()) :: status() | {:error, :not_found}
  def status(agent), do: call(agent, :status)

  @doc "Reads conversation, lifecycle state, and durable identity in one call."
  @spec snapshot(agent()) :: Snapshot.t() | {:error, :not_found}
  def snapshot(agent), do: call(agent, :snapshot)

  @doc """
  Accepts decisions only while their calls are parked, acknowledging acceptance
  before returning.

  `:by` names the `Wardrik.Principal` deciding, carried on each
  `{:call_decided, call_id, decision, by}` event. `{:error, :unrecorded}`
  means the decisions could not be written to the agent's log, and were not
  taken.
  """
  @spec decide(agent(), map(), keyword()) ::
          :ok | {:error, :not_found | :not_parked | :stale_decision | :unrecorded}
  def decide(agent, decisions, opts \\ []) when is_map(decisions) and is_list(opts),
    do: call(agent, {:decide, decisions, Keyword.get(opts, :by)})

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
  and a no-op when nothing is parked. `:by` names the `Wardrik.Principal`
  deciding, as `decide/3` takes it.

      Wardrik.Agent.resume("acme/jon/researcher", %{"call_abc" => :approve})
      Wardrik.Agent.resume(pid, %{"call_abc" => {:deny, "Not this quarter."}})
  """
  @spec resume(agent(), %{String.t() => Turn.decision()}, keyword()) ::
          :ok | {:error, :not_found}
  def resume(agent, decisions, opts \\ []) when is_map(decisions) and is_list(opts),
    do: cast(agent, {:resume, decisions, Keyword.get(opts, :by)})

  @doc """
  What this agent is waiting on, as `{call, prompt}` pairs, or `[]` when it is
  not parked.
  """
  @spec parked(agent()) :: [{Wardrik.Tool.call(), String.t()}] | {:error, :not_found}
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
    :ok = Bus.subscribe(state.agent_id)

    started =
      Event.new(
        Source.root(state.agent_id),
        {:agent_started, node(), State.status(state).state, state.generation}
      )

    state = State.logged(state, Writer.open(state.log, started))
    :ok = Bus.publish(started)

    {:ok, state, meta: State.meta(state), permanent: true, sync_every_ms: @sync_every_ms}
  end

  # -- messages --------------------------------------------------------------

  @impl DurableServer
  def handle_call({:configure, opts}, _from, state) do
    next = state |> State.configure(opts) |> redecide()
    {:reply, :ok, next, meta: State.meta(next), sync: true}
  end

  def handle_call({:checkpoint, checkpoint}, {pid, _tag}, state) do
    case State.checkpointed(state, pid, checkpoint) do
      {:ok, next} -> {:reply, :ok, next, meta: State.meta(next), sync: true}
      :stale -> {:reply, {:error, :not_the_running_turn}, state}
    end
  end

  def handle_call(:get_context, _from, state), do: {:reply, state.context, state}
  def handle_call(:status, _from, state), do: {:reply, State.status(state), state}
  def handle_call(:parked, _from, state), do: {:reply, State.waiting_on(state), state}
  def handle_call(:snapshot, _from, state), do: {:reply, State.snapshot(state), state}

  def handle_call({:decide, decisions, by}, _from, state) do
    ids = Enum.map(State.waiting_on(state), fn {call, _prompt} -> call.id end)

    cond do
      ids == [] ->
        {:reply, {:error, :not_parked}, state}

      map_size(decisions) == 0 or not Enum.all?(Map.keys(decisions), &(&1 in ids)) ->
        {:reply, {:error, :stale_decision}, state}

      true ->
        case resume_turn(state, decisions, by) do
          {:ok, next} -> {:reply, :ok, next, meta: State.meta(next), sync: true}
          {:error, next} -> {:reply, {:error, :unrecorded}, next}
        end
    end
  end

  @impl DurableServer
  def handle_cast({:ask, %Message{} = message}, state) do
    {state, effects} = State.queue(state, message)

    state |> perform(effects) |> advance(sync: true)
  end

  def handle_cast(:interrupt, state) do
    {state, effects} = State.interrupt(state)

    state |> perform(effects) |> advance(sync: true)
  end

  def handle_cast({:resume, decisions, by}, state) do
    case resume_turn(state, decisions, by) do
      {:ok, next} -> stay(next, sync: true)
      {:error, next} -> stay(next)
    end
  end

  defp redecide(state) do
    if State.stale?(state) do
      {_recorded, state} = resume_turn(state, %{}, nil)
      state
    else
      state
    end
  end

  defp resume_turn(state, decisions, by) do
    case State.resume(state) do
      {:resume, scope, turn, started_at} ->
        resume_parked(state, journaled(scope), turn, started_at, decisions, by)

      :none ->
        {:ok, state}
    end
  end

  defp resume_parked(state, scope, turn, started_at, decisions, by) do
    decided =
      for {call, _prompt} <- Turn.waiting(turn),
          Map.has_key?(decisions, call.id),
          do: Event.new(scope.source, {:call_decided, call.id, decisions[call.id], by})

    with {:ok, state} <- log_ahead(state, decided) do
      Enum.each(decided, &Bus.publish/1)
      Event.emit(scope.source, {:turn_resumed, decisions})
      task = run(fn -> State.apply_resumer(state, scope, turn, decisions) end)

      {:ok, State.resumed(state, task, scope, turn, started_at)}
    end
  end

  # Decisions are written to the log before they take effect, so none takes
  # effect unrecorded.
  defp log_ahead(state, events) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case Writer.append_ahead(state.log, event) do
        {:ok, log} ->
          {:cont, {:ok, State.logged(state, log)}}

        {:error, reason, log} ->
          Logger.warning("Decisions for #{state.agent_id} not taken: #{inspect(reason)}")
          {:halt, {:error, State.logged(state, log)}}
      end
    end)
  end

  @impl DurableServer
  def handle_continue(:maybe_run, state) do
    case State.take(state) do
      {:run, messages, state} -> stay(start(state, messages))
      {:replay, scope, checkpoint, state} -> stay(replay(state, scope, checkpoint))
      {:compact, scope, state} -> stay(compact(state, scope))
      :none -> stay(state)
    end
  end

  @impl DurableServer
  def handle_info(:maybe_run, state), do: advance(state)

  def handle_info({ref, result}, state) when is_reference(ref) do
    cond do
      State.running?(state, ref) ->
        Process.demonitor(ref, [:flush])
        state |> answered(result) |> advance(sync: true)

      State.compacting?(state, ref) ->
        Process.demonitor(ref, [:flush])
        state |> settle(State.compacted(state, result)) |> advance(sync: true)

      true ->
        stay(state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    if State.compacting?(state, ref) do
      Logger.error("Compaction crashed: #{inspect(reason)}")
      state |> settle(State.compacted(state, {:error, reason})) |> advance(sync: true)
    else
      down(state, ref, reason)
    end
  end

  def handle_info({:kill, tag}, state) do
    case State.kill(state, tag) do
      {:kill, state, effects} -> state |> perform(effects) |> advance(sync: true)
      :stale -> stay(state)
    end
  end

  # The agent's own events, which it writes to its log, and which is how it
  # follows the delegations its turn starts. The fleet hears of them only when
  # the summary changes.
  def handle_info(%Event{source: %{agent_id: id}} = event, %State{agent_id: id} = state) do
    next = state |> State.observe(event) |> log(event)

    if State.meta(next) == State.meta(state), do: {:noreply, next}, else: stay(next)
  end

  def handle_info(%Event{}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    stay(state)
  end

  # A write the log could not make is the writer's to report.
  defp log(state, event) do
    case Writer.append(state.log, event) do
      {:ok, log} -> State.logged(state, log)
      {:error, _reason, log} -> State.logged(state, log)
    end
  end

  defp down(state, ref, reason) do
    if State.running?(state, ref) do
      Logger.error("Turn crashed: #{inspect(reason)}")
      state |> settle(State.failed(state, reason)) |> advance(sync: true)
    else
      stay(state)
    end
  end

  # -- returns ---------------------------------------------------------------

  # Every return republishes this agent's metadata, which is what `Wardrik.Fleet`
  # lists. `sync: true` writes the state to the store before returning.
  defp advance(state, opts \\ []) do
    {:noreply, state, {:continue, :maybe_run}, [meta: State.meta(state)] ++ opts}
  end

  defp stay(state, opts \\ []) do
    {:noreply, state, [meta: State.meta(state)] ++ opts}
  end

  # -- turns -----------------------------------------------------------------

  defp start(state, messages) do
    context = Enum.reduce(messages, state.context, &Context.append(&2, Context.user(&1.text)))
    scope = journaled(State.turn_scope(state))

    Event.emit(scope.source, {:turn_started, messages})
    task = run(fn -> State.apply_runner(state, scope, context) end)

    State.started(state, task, scope, context, System.monotonic_time())
  end

  defp compact(state, scope) do
    task = run(fn -> Wardrik.Compaction.run(scope, state.context) end)
    State.compacting(state, task, System.monotonic_time())
  end

  defp replay(state, scope, checkpoint) do
    scope = journaled(scope)
    Event.emit(scope.source, {:turn_started, []})
    task = run(fn -> State.apply_replayer(state, scope, checkpoint) end)

    State.replayed(state, task, scope, checkpoint, System.monotonic_time())
  end

  # Each turn hands its batches of tool calls to this process before running
  # them, which writes them down.
  defp journaled(scope), do: %{scope | journal: self()}

  # A turn belongs to the agent that started it: one whose agent stopped, or
  # moved to another node, is killed rather than running a batch its successor
  # is replaying.
  defp run(fun) do
    agent = self()

    Task.Supervisor.async_nolink(Wardrik.TaskSupervisor, fn ->
      Wardrik.Tether.to(agent)
      fun.()
    end)
  end

  defp answered(state, %Turn{state: :done, messages: messages}),
    do: settle(state, State.settled(state, messages))

  # A waiting turn is held as it is written down, with no scope.
  defp answered(state, %Turn{state: :waiting} = turn),
    do: settle(state, State.parked(state, Turn.under(turn, nil)))

  defp answered(state, %Turn{state: :failed, error: reason}) do
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
    Turn.yield(pid)
    state
  end

  defp apply_effect({:stop_now, pid}, state) do
    Turn.interrupt(pid)
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

  defp apply_effect({:close_turn, scope}, state) do
    %{agent_id: agent_id, log: %{head: through}} = state
    cutoff = DateTime.add(DateTime.utc_now(), -Log.retention_days(), :day)

    Task.Supervisor.start_child(Wardrik.TaskSupervisor, fn ->
      Wardrik.Ledger.forget(scope.ledger, agent_id, scope.source.trace.trace_id)
      Log.trim(agent_id, through, cutoff)
    end)

    state
  end
end
