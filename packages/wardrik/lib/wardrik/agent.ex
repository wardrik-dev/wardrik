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

  An agent is a `DurableServer`: one process per ID across the cluster, state
  written to the store on every change that matters, and restarted elsewhere
  when its node is lost. Start one with `Wardrik.Fleet.spawn/2`.

  Every function here takes a pid or a `Wardrik.AgentID`, and an ID nothing
  holds answers `{:error, :not_found}`.

      Wardrik.Agent.ask(~A"acme/@jon/researcher", "What changed this week?")

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

  A call parked to resolve a credential the person has yet to connect waits
  the same way, and the agent approves it itself once
  `Wardrik.Credential.available/3` says the credential can be resolved, as
  the `Wardrik.Principal` that connected it; the turn carries on with nobody
  asked.

  A parked turn is written to the store and outlives the node it parked on. A
  turn lost after being resumed goes on with the decisions it was given, which
  are not asked for again. Resuming gives the turn this node's tools and a
  fresh budget.

  ## A history that grows

  As a turn begins, its task hands the agent's history to its config's
  `Wardrik.History`, before the messages it answers join it. The default,
  `Wardrik.Compaction`, summarises the older part of a history that has
  outgrown the model's window, with the agent's own model. The agent keeps
  what it answers, and `{:context_compacted, stats}` reports it on the turn's
  trace. A history that cannot be rewritten is kept as it was, and the turn
  runs regardless.

  `clear/1` empties the history of an idle agent, and reports
  `{:context_cleared, dropped}`, with how many messages it held. It is how an
  agent is rid of the labels of what its history held, such as content from
  outside: until then, every turn carries them. See `Wardrik.Agent.State`.

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
  for is read from the agent's ID.

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
  alias Wardrik.Agent.State.Stored
  alias Wardrik.Agent.State.View
  alias Wardrik.Credential
  alias Wardrik.Event
  alias Wardrik.Event.Bus
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Event.Source
  alias Wardrik.Fleet
  alias Wardrik.History
  alias Wardrik.LLM.Turn

  @typedoc "An agent: the pid of one, or its ID."
  @type agent() :: pid() | Wardrik.AgentID.t()

  @typedoc "Whether a turn is in flight, how many messages wait behind it, and the model."
  @type status() :: View.status()

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
  @spec initial_state(keyword(), Wardrik.AgentID.t()) :: State.t()
  def initial_state(opts, id), do: State.new(opts, id)

  @doc """
  Gives the agent a new `:config` and new seams for the turns it starts from
  now on, and writes them to the store. See `Wardrik.Agent.State.configure/2`.

  An agent waiting on a person under hooks other than the ones it is given is
  resumed with no decisions, so its new hooks decide the calls it waits on:
  each goes ahead, is refused, or waits again on what the new hooks ask.

      Wardrik.Agent.configure(~A"acme/@jon/researcher", config: config, hooks: hooks)
  """
  @spec configure(agent(), keyword()) :: :ok | {:error, :not_found}
  def configure(agent, opts) when is_list(opts), do: call(agent, {:configure, opts})

  @doc """
  Queues a message for the agent to answer.

  `:id` names the message, a new UUIDv7 when left out. The agent announces it
  as `{:message_queued, message}` and takes it once, however many times the
  same id is sent. `:sender` is the `Wardrik.Principal` who sent it, which
  its event carries and the model reads; see `Wardrik.Agent.Message`.
  `:labels` are what the message holds, as `Wardrik.Label`s, which its turn
  carries from its start: `["outside"]` for a message from someone who is not
  the agent's own.
  """
  @spec ask(agent(), String.t(), keyword()) :: :ok | {:error, :not_found}
  def ask(agent, question, opts \\ []) when is_binary(question) and is_list(opts) do
    message =
      Message.new(question, Keyword.get(opts, :id),
        sender: Keyword.get(opts, :sender),
        labels: Keyword.get(opts, :labels, [])
      )

    cast(agent, {:ask, message})
  end

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
  Empties this agent's history, keeping its config and queue.
  `{:error, :busy}` unless it is idle.
  """
  @spec clear(agent()) :: :ok | {:error, :not_found | :busy}
  def clear(agent), do: call(agent, :clear)

  @doc """
  Stops whatever this agent is doing and discards whatever is queued.

  Non-blocking, and safe when the agent is idle. A parked turn is abandoned,
  which is the only way to get rid of one without answering it.
  """
  @spec interrupt(agent()) :: :ok | {:error, :not_found}
  def interrupt(agent), do: cast(agent, :interrupt)

  @doc """
  Answers the calls a parked turn stopped on and carries it on.

  `decisions` maps a tool call id to `:approve`, `{:approve, note}` or
  `{:deny, reason}`: the model reads a note beside the call's answer, and a
  reason in place of it. A note never changes the call, which runs as the
  model wrote it. Calls left out stay parked, so several people can answer
  one call each. Non-blocking, and a no-op when nothing is parked. `:by`
  names the `Wardrik.Principal` deciding, as `decide/3` takes it.

      Wardrik.Agent.resume(~A"acme/@jon/researcher", %{"call_abc" => :approve})
      Wardrik.Agent.resume(pid, %{"call_abc" => {:approve, "Only to staging."}})
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
  defp resolve(%Wardrik.AgentID{} = id), do: Fleet.whereis(id)

  # -- durability ------------------------------------------------------------

  @impl DurableServer
  def dump_state(%State{} = state), do: Stored.dump(state)

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: Stored.load(dumped)

  # DurableServer's callback type leaves out the continue its server takes
  # from `init`.
  @dialyzer {:nowarn_function, init: 1}
  @impl DurableServer
  def init(%State{} = state) do
    {:ok, state, {:continue, :open},
     meta: View.meta(state), permanent: true, sync_every_ms: @sync_every_ms}
  end

  # -- messages --------------------------------------------------------------

  @impl DurableServer
  def handle_call({:configure, opts}, _from, state) do
    next = state |> State.configure(opts) |> redecide()
    {:reply, :ok, next, meta: View.meta(next), sync: true}
  end

  def handle_call({:checkpoint, checkpoint}, {pid, _tag}, state) do
    case State.checkpointed(state, pid, checkpoint) do
      {:ok, next} -> {:reply, :ok, next, meta: View.meta(next), sync: true}
      :stale -> {:reply, {:error, :not_the_running_turn}, state}
    end
  end

  def handle_call({:kept, context}, {pid, _tag}, state) do
    case State.kept(state, pid, context) do
      {:ok, next} -> {:reply, :ok, next, sync: true}
      :stale -> {:reply, {:error, :not_the_running_turn}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    case State.clear(state) do
      {:ok, next, effects} ->
        next = perform(next, effects)
        {:reply, :ok, next, meta: View.meta(next), sync: true}

      {:error, :busy} ->
        {:reply, {:error, :busy}, state}
    end
  end

  def handle_call(:get_context, _from, state), do: {:reply, state.context, state}
  def handle_call(:status, _from, state), do: {:reply, View.status(state), state}
  def handle_call(:parked, _from, state), do: {:reply, State.waiting_on(state), state}
  def handle_call(:snapshot, _from, state), do: {:reply, View.snapshot(state), state}

  def handle_call({:decide, decisions, by}, _from, state) do
    ids = Enum.map(State.waiting_on(state), fn {call, _prompt} -> call.id end)

    cond do
      ids == [] ->
        {:reply, {:error, :not_parked}, state}

      map_size(decisions) == 0 or not Enum.all?(Map.keys(decisions), &(&1 in ids)) ->
        {:reply, {:error, :stale_decision}, state}

      true ->
        case resume_turn(state, decisions, by) do
          {:ok, next} -> {:reply, :ok, next, meta: View.meta(next), sync: true}
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

  def handle_cast({:resume, decisions, by}, state), do: decided(state, decisions, by)

  defp decided(state, decisions, by) do
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
      {:ok, carry_on(state, scope, turn, decisions, started_at)}
    end
  end

  defp carry_on(state, scope, turn, decisions, started_at) do
    Event.emit(scope.source, {:turn_resumed, decisions})
    task = run(fn -> State.apply_resumer(state, scope, turn, decisions) end)

    State.resumed(state, task, scope, turn, decisions, started_at)
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

  # The log opens here rather than in `init`, so the fleet's start does not
  # wait on the store. A continue runs before any message, so nothing reads
  # `state.log` until it is open.
  @impl DurableServer
  def handle_continue(:open, state) do
    :ok = Bus.subscribe(state.agent_id)

    started =
      Event.new(
        Source.root(state.agent_id),
        {:agent_started, node(), View.status(state).state, state.generation}
      )

    state = State.logged(state, Writer.open(state.log, started))
    :ok = Bus.publish(started)

    advance(state)
  end

  def handle_continue(:maybe_run, state) do
    case State.take(state) do
      {:run, messages, state} ->
        stay(start(state, messages))

      {:replay, scope, checkpoint, state} ->
        stay(replay(state, scope, checkpoint))

      {:resume, scope, turn, decisions, state} ->
        stay(resume_again(state, scope, turn, decisions))

      :none ->
        stay(state)
    end
  end

  @impl DurableServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    if State.running?(state, ref) do
      Process.demonitor(ref, [:flush])
      state |> answered(result) |> advance(sync: true)
    else
      stay(state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref),
    do: down(state, ref, reason)

  def handle_info({:kill, ref}, state) do
    case State.kill(state, ref) do
      {:kill, state, effects} -> state |> perform(effects) |> advance(sync: true)
      :stale -> stay(state)
    end
  end

  # Every agent hears of every credential; one that parked a call to resolve
  # it approves the call.
  def handle_info(%Credential.Available{ref: ref, owner: owner, by: by}, state) do
    case State.awaiting(state, ref, owner) do
      [] -> {:noreply, state}
      ids -> decided(state, Map.new(ids, &{&1, :approve}), by)
    end
  end

  # The agent's own events, which it writes to its log.
  def handle_info(%Event{source: %{agent_id: id}} = event, %State{agent_id: id} = state),
    do: {:noreply, log(state, event)}

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
    {:noreply, state, {:continue, :maybe_run}, [meta: View.meta(state)] ++ opts}
  end

  defp stay(state, opts \\ []) do
    {:noreply, state, [meta: View.meta(state)] ++ opts}
  end

  # -- turns -----------------------------------------------------------------

  defp start(state, messages) do
    scope = state |> State.turn_scope() |> journaled() |> heard(messages)

    Event.emit(scope.source, {:turn_started, messages})
    task = run(fn -> State.apply_runner(state, scope, kept(state, scope, messages)) end)

    State.started(state, task, scope, asked(state.context, messages), System.monotonic_time())
  end

  # What the agent's history keeps of itself, with the turn's messages after
  # it, word for word. A history rewritten is handed to this agent to keep, as
  # a batch is, before the turn runs on it.
  defp kept(state, scope, messages) do
    case History.prepare(state.config.history, state.context, scope) do
      :keep ->
        asked(state.context, messages)

      {:ok, history, stats} ->
        context = asked(history, messages)
        :ok = GenServer.call(scope.journal, {:kept, context}, :timer.seconds(30))
        Event.emit(scope.source, {:context_compacted, stats})
        context
    end
  end

  defp asked(context, messages),
    do: Enum.reduce(messages, context, &Context.append(&2, Context.user(Message.content(&1))))

  defp replay(state, scope, checkpoint) do
    scope = journaled(scope)
    Event.emit(scope.source, {:turn_started, []})
    task = run(fn -> State.apply_replayer(state, scope, checkpoint) end)

    State.replayed(state, task, scope, checkpoint, System.monotonic_time())
  end

  # Its decisions were logged when they were taken.
  defp resume_again(state, scope, turn, decisions),
    do: carry_on(state, journaled(scope), turn, decisions, System.monotonic_time())

  # Each turn hands its batches of tool calls to this process before running
  # them, which writes them down.
  defp journaled(scope), do: %{scope | journal: self()}

  defp heard(scope, messages),
    do: %{
      scope
      | labels: Enum.reduce(messages, scope.labels, &Wardrik.Label.union(&2, &1.labels))
    }

  # A turn belongs to the agent that started it: one whose agent stopped, or
  # moved to another node, is killed rather than running a batch its successor
  # is replaying.
  defp run(fun) do
    agent = self()

    Task.Supervisor.async_nolink(Wardrik.Tasks.supervisor(), fn ->
      Wardrik.Tether.to(agent)
      fun.()
    end)
  end

  defp answered(state, %Turn{state: :done, messages: messages} = turn),
    do: settle(state, State.settled(state, messages, turn.labels))

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

  defp apply_effect({:arm_kill, task_ref, ms, dropped}, state) do
    timer = Process.send_after(self(), {:kill, task_ref}, ms)
    State.arm(state, timer, dropped)
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

    Task.Supervisor.start_child(Wardrik.Tasks.supervisor(), fn ->
      Wardrik.Ledger.forget(scope.ledger, agent_id, scope.source.trace.trace_id)
      Log.trim(agent_id, through, cutoff)
    end)

    state
  end
end
