defmodule Wardrik.Agent do
  @moduledoc """
  Owns one agent's conversation and serializes turns against it.

  `ask/2` is non-blocking. Messages are queued in `pending` and drained one turn
  at a time: exactly one turn task runs at once, and this process is the only
  writer of `history`. Order is therefore a structural property rather than
  something callers have to coordinate.

  The turn itself runs in a `Task.Supervisor.async_nolink/3` task, so a failure
  inside the model's client or a tool cannot take the agent down.

  Stream and tool events do not pass through this process at all. The turn
  publishes them through its run, and any number of listeners on any node can
  follow them with `Wardrik.subscribe/2`.

  A message arriving while a turn is running joins that turn rather than
  waiting for it: the turn is asked to stop at its next boundary, and the
  messages queued behind it start the next one against the history it left.
  Nothing in that path knows where the message came from.

  ## Durable and keyed

  An agent is a `DurableServer`: one process per ID across the cluster, state
  written to the store on every change that matters, and restarted elsewhere
  when its node is lost. Start one with `Wardrik.Fleet.spawn/2`.

  Every function here takes a pid or a `Wardrik.AgentAddress`, and an ID nothing
  holds answers `{:error, :not_found}`. Given an ID, each takes the
  `Wardrik.Host` whose definitions start an agent the store does not hold,
  as `:host`; see `Wardrik.Fleet.whereis/2`.

      Wardrik.Agent.ask(~A"acme/@jon/researcher", "What changed this week?", host: host)

  ## Sleeping

  An agent with nothing to do for its `:idle_timeout`, #{div(Wardrik.Agent.State.default_idle_timeout(), 60_000)}
  minutes unless it is given another, writes itself down and stops, and
  reports `Wardrik.Bus.AgentStopped`. Nothing running, it costs nothing.
  It sleeps only with no turn running and nothing queued; a turn parked on a
  person does not keep it awake.

  Given its ID, every function here but `interrupt/1` reaches the agent
  through `Wardrik.Fleet.whereis/2`, which wakes a sleeping one from the
  store, or starts one from its definition; `interrupt/1` has nothing to stop
  in one asleep. Each call, cast and finished turn counts as something done.

  ## Interrupting

  `interrupt/1` asks the running turn to stop, drops everything queued behind
  it, and kills the turn if it has not returned within its grace. A tool
  already running does not read its mailbox, which is what the grace covers.
  Either way the agent settles idle and reports what it stopped as
  `Wardrik.Bus.TurnInterrupted`.

  `Wardrik.LLM.ToolRunner.kill_call/2` stops one tool call rather than the turn.

  ## Waiting for a person

  A `Wardrik.Hook` that asks a person about a call parks the turn. The agent holds
  what it was doing, reports `:parked`, and does nothing until `resume/2`
  answers the calls it stopped on, and emits `Wardrik.Bus.CallDecided` for each, with the `Wardrik.Principal` a caller names as `:by`. Messages
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

  A turn may rewrite the history it begins on, as `Wardrik.LLM.Turn`
  summarises one that has outgrown its model's window, and hands what it
  keeps to the agent, which keeps it from then on.

  `clear/1` empties the history of an idle agent, and reports
  `Wardrik.Bus.ContextCleared`, with how many messages it held. It is how an
  agent is rid of the labels of what its history held, such as content from
  outside: until then, every turn carries them. See `Wardrik.Agent.State`.

  ## A turn lost part way

  Each turn hands the agent every batch of tool calls before running it, and
  the agent writes the batch to the store before the calls run. A turn lost
  after that comes back replaying from its last batch, with the same calls, and
  the `Wardrik.Ledger` in the host's store answers for any that already ran.
  See `Wardrik.LLM.Turn`.

  A turn is tethered to its agent, and each tool call to its turn, so an agent
  that stops or moves leaves nothing of its turn running beside the replay.
  Once a turn has ended for good, finished, failed or abandoned, the ledger
  forgets its calls.

  ## What a host supplies

  An agent's `:config` is its `Wardrik.Runtime.Settings`, which name the
  host's `Wardrik.Runtime` that makes its turns, `Wardrik.LLM.Runtime` for a
  `Wardrik.LLM.Config`; see `Wardrik.Host.runtime/2`. Beyond it, an agent
  takes the seams every run it roots is built with: `:hooks` decide whether
  a tool call may run and a model call be made, `:retry` whether one that
  failed is asked again, and `:timeout` bounds the whole turn. Each is
  optional: `Wardrik.Run.root/3` says what each is without one. Who the work
  is for is read from the agent's ID. What a model call actually is, and who
  pays for it, is the host's `Wardrik.LLM.Dispatch`, the same for every
  agent.

  A config's tools are built on whichever node runs the agent. One that node
  cannot build is left out with a warning.

  ## The host it runs on

  Each time the agent starts, wakes from the store, or restarts on another
  node, the fleet hands it the `Wardrik.Host` that `Wardrik.Core` was started
  with (see `Wardrik.Fleet.Supervisor`). It keeps it in memory and never
  writes it down, so what the store holds of an agent names no module of
  the host's. As it starts it asks the host's `Wardrik.Specs` for the
  spec it runs on now, `c:Wardrik.Specs.current/2`, and takes its
  config, seams and idle timeout as `configure/2` gives them, so a
  definition changed while it slept is the one it wakes with; `:none`
  leaves it as it was. Every turn's run carries the host, for the tools
  that act on the agents as the agent, as `Wardrik.Catalog.Tools` does.

  The agent adds events of its own so subscribers can follow its state
  without polling: `Wardrik.Bus.TurnStarted`, `Wardrik.Bus.TurnFinished`,
  `Wardrik.Bus.TurnFailed`, `Wardrik.Bus.TurnInterrupted`,
  `Wardrik.Bus.TurnResumed` and `Wardrik.Bus.CallDecided`
  on the turn's root span, so a subscriber can tell them from events the
  turn's own work produced; and `Wardrik.Bus.MessageQueued` as a message
  arrives and `Wardrik.Bus.AgentStarted` each time the agent is loaded,
  on the root of a trace of their own.

  It folds its own events into what it is doing now, a
  `Wardrik.Agent.Activity`, and announces each change as
  `Wardrik.Bus.ActivityChanged`, live, on the span of the event that
  changed it. A client attaching mid-turn can catch up with `status/1` or
  `snapshot/1`, which carry it.

  ## Answering another agent

  A message may name agents its answer goes to, as one agent's message to
  another names the agent that sent it; see `Wardrik.Agent.Message`. The turn
  that takes it sends each of them a message of its own, from this agent, the
  `Wardrik.Principal` its resource names:

    * where the turn finishes, its answer, the text of its last assistant
      message, holding the labels the turn ended with, such as `"outside"`
      for content it read from outside, so what the asker reads carries them
      as a tool's answer would
    * where it fails, a word that it failed, and where it is interrupted or
      the message is dropped from the queue, a word that it stopped

  A turn waiting on a person answers once someone decides. One the agent
  takes up again, after it stopped, moved or lost its node, still owes the
  answers, which are written down with it. The answer is sent once the turn
  has ended, under an id made from the message's, so one sent again after a
  node is lost is taken once. An asker asleep wakes for it; one forgotten is
  never told, and an agent forgotten before it answers tells nobody. Several
  messages one turn takes are each answered with that turn's answer.

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

  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.Agent.Spec
  alias Wardrik.Agent.State
  alias Wardrik.Agent.State.Stored
  alias Wardrik.Agent.State.View
  alias Wardrik.AgentAddress
  alias Wardrik.Bus
  alias Wardrik.Bus.Source
  alias Wardrik.Conversation
  alias Wardrik.Conversation.User
  alias Wardrik.Credential
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Fleet
  alias Wardrik.Host
  alias Wardrik.Runtime
  alias Wardrik.Runtime.Settings
  alias Wardrik.Turn
  alias Wardrik.Turn.Signal

  @typedoc "An agent: the pid of one, or its `Wardrik.AgentAddress`."
  @type agent() :: pid() | Wardrik.AgentAddress.t()

  @typedoc "Whether a turn is in flight, how many messages wait behind it, and the model."
  @type status() :: View.status()

  @typedoc "What an interrupt stopped."
  @type stats() :: State.stats()

  # Transitions worth keeping sync on their own. This is the backstop.
  @sync_every_ms 30_000

  @doc """
  The state an agent starts life with, for `Wardrik.Fleet.spawn/2` to hand over.

  Options: `:config`, `:history`, `:grace`, `:idle_timeout`, `:wake_only`,
  and the run's `Wardrik.Run.seams/0`.

  `:idle_timeout` is how long the agent may have nothing to do before it
  sleeps, in milliseconds or `:infinity`; see "Sleeping" above. `:wake_only`
  starts nothing the host does not hold: the agent comes up from what the
  store holds, or else from its definition, and one with neither deletes
  itself as it starts.

  `:grace` is how long an interrupted turn is given to answer before it is
  killed, #{State.default_grace()}ms by default.
  """
  @spec initial_state(keyword(), Wardrik.AgentAddress.t()) :: State.t()
  def initial_state(opts, id), do: State.new(opts, id)

  @doc """
  Gives the agent a new `:config` and new seams for the turns it starts from
  now on, and writes them to the store. See `Wardrik.Agent.State.configure/2`.

  An agent waiting on a person under hooks other than the ones it is given is
  resumed with no decisions, so its new hooks decide the calls it waits on:
  each goes ahead, is refused, or waits again on what the new hooks ask.

      Wardrik.Agent.configure(~A"acme/@jon/researcher", config: config, hooks: hooks, host: host)
  """
  @spec configure(agent(), keyword()) :: :ok | {:error, :not_found}
  def configure(agent, opts) when is_list(opts) do
    {whereis, opts} = Keyword.split(opts, [:host])
    call(agent, {:configure, opts}, whereis)
  end

  @doc """
  Queues a message for the agent to answer.

  `:id` names the message, a new UUIDv7 when left out. The agent announces it
  as `Wardrik.Bus.MessageQueued` and takes it once, however many times the
  same id is sent. `:sender` is the `Wardrik.Principal` who sent it, which
  its event carries and the model reads; see `Wardrik.Agent.Message`.
  `:labels` are what the message holds, as `Wardrik.Label`s, which its turn
  carries from its start: `["outside"]` for a message from someone who is not
  the agent's own. `:reply_to` lists the agents its answer goes to, besides
  the log; see "Answering another agent" above. `:host` is as above.
  """
  @spec ask(agent(), String.t(), keyword()) :: :ok | {:error, :not_found}
  def ask(agent, question, opts \\ []) when is_binary(question) and is_list(opts) do
    message =
      Message.new(question, Keyword.get(opts, :id),
        sender: Keyword.get(opts, :sender),
        labels: Keyword.get(opts, :labels, []),
        reply_to: Keyword.get(opts, :reply_to, [])
      )

    queue(agent, message, Keyword.take(opts, [:host]))
  end

  @doc "Queues `message` for the agent to answer, as `ask/3` does with the message it makes."
  @spec queue(agent(), Message.t(), host: Wardrik.Host.t()) :: :ok | {:error, :not_found}
  def queue(agent, %Message{} = message, opts \\ []), do: cast(agent, {:ask, message}, opts)

  @doc "The agent's history, the messages of a turn it has taken included."
  @spec history(agent(), host: Wardrik.Host.t()) :: Conversation.t() | {:error, :not_found}
  def history(agent, opts \\ []), do: call(agent, :history, opts)

  @spec status(agent(), host: Wardrik.Host.t()) :: status() | {:error, :not_found}
  def status(agent, opts \\ []), do: call(agent, :status, opts)

  @doc "Reads conversation, lifecycle state, and durable identity in one call."
  @spec snapshot(agent(), host: Wardrik.Host.t()) :: Snapshot.t() | {:error, :not_found}
  def snapshot(agent, opts \\ []), do: call(agent, :snapshot, opts)

  @doc """
  Accepts decisions only while their calls are parked, and only from a
  `:token` that may decide them, acknowledging acceptance before returning.

  A token may decide them where it allows `agent.decide` on the agent, or
  where its principal asked for the turn that waits and acts directly,
  assumed by nobody: `Wardrik.Principal.same?/2` with its sender, so whoever
  asks may approve what their own turn does, and an agent acting for them
  may not. Anyone else is `{:error, :forbidden}`. The token's principal is
  carried on each `Wardrik.Bus.CallDecided` event as who decided. `{:error,
  :unrecorded}` means the decisions could not be written to the agent's
  log, and were not taken. `:host` is as `ask/3` takes it.
  """
  @spec decide(agent(), map(), token: Wardrik.Token.t(), host: Wardrik.Host.t()) ::
          :ok | {:error, :not_found | :not_parked | :stale_decision | :forbidden | :unrecorded}
  def decide(agent, decisions, opts) when is_map(decisions) do
    %Wardrik.Token{} = token = Keyword.fetch!(opts, :token)
    call(agent, {:decide, decisions, token}, opts)
  end

  @doc """
  Empties this agent's history, keeping its config and queue.
  `{:error, :busy}` unless it is idle.
  """
  @spec clear(agent(), host: Wardrik.Host.t()) :: :ok | {:error, :not_found | :busy}
  def clear(agent, opts \\ []), do: call(agent, :clear, opts)

  @doc """
  Stops whatever this agent is doing and discards whatever is queued.

  Non-blocking, and safe when the agent is idle. A parked turn is abandoned,
  which is the only way to get rid of one without answering it.
  """
  @spec interrupt(agent()) :: :ok | {:error, :not_found}
  def interrupt(pid) when is_pid(pid), do: GenServer.cast(pid, :interrupt)

  def interrupt(id) do
    case Fleet.held_pid(id, wake: false) do
      nil -> {:error, :not_found}
      pid -> interrupt(pid)
    end
  end

  @doc """
  Answers the calls a parked turn stopped on and carries it on.

  `decisions` maps a tool call id to `:approve`, `{:approve, note}` or
  `{:deny, reason}`: the model reads a note beside the call's answer, and a
  reason in place of it. A note never changes the call, which runs as the
  model wrote it. Calls left out stay parked, so several people can answer
  one call each. Non-blocking, and a no-op when nothing is parked. `:by`
  names the `Wardrik.Principal` deciding, carried on each
  `Wardrik.Bus.CallDecided` event. Unlike `decide/3`, it asks no
  token, so it is for code that already holds the agent, never for a
  surface people decide through. `:host` is as `ask/3` takes it.

      Wardrik.Agent.resume(~A"acme/@jon/researcher", %{"call_abc" => :approve}, host: host)
      Wardrik.Agent.resume(pid, %{"call_abc" => {:approve, "Only to staging."}})
      Wardrik.Agent.resume(pid, %{"call_abc" => {:deny, "Not this quarter."}})
  """
  @spec resume(agent(), Turn.decisions(), keyword()) ::
          :ok | {:error, :not_found}
  def resume(agent, decisions, opts \\ []) when is_map(decisions) and is_list(opts),
    do: cast(agent, {:resume, decisions, Keyword.get(opts, :by)}, Keyword.take(opts, [:host]))

  @doc """
  What this agent is waiting on, as `{call, prompt}` pairs, or `[]` when it is
  not parked.
  """
  @spec parked(agent(), host: Wardrik.Host.t()) ::
          [{Wardrik.Tool.call(), String.t()}] | {:error, :not_found}
  def parked(agent, opts \\ []), do: call(agent, :parked, opts)

  defp cast(agent, message, opts) do
    case resolve(agent, opts) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, message)
    end
  end

  defp call(agent, message, opts) do
    case resolve(agent, opts) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, message)
    end
  end

  defp resolve(pid, _opts) when is_pid(pid), do: pid
  defp resolve(id, opts), do: Fleet.whereis(id, opts)

  # -- durability ------------------------------------------------------------

  @impl DurableServer
  def dump_state(%State{} = state), do: Stored.dump(state)

  # A state read from the store has a version; one with none is the state the
  # caller handed over, for an agent the store did not hold. One this release
  # cannot read, as after a change to what an agent writes down, is rescued
  # rather than left to crash every start: the agent starts as one the store
  # does not hold.
  @impl DurableServer
  def load_state(nil, dumped), do: Stored.load(dumped)

  def load_state(_old_vsn, dumped) do
    %{Stored.load(dumped) | wake_only: false}
  rescue
    error in [ArgumentError, KeyError, FunctionClauseError] ->
      Logger.warning(
        "#{dumped.agent_id} kept a state this release cannot read (#{inspect(error.__struct__)}); " <>
          "it starts from its definition, where it has one"
      )

      State.new([wake_only: true], dumped.agent_id)
  end

  # DurableServer's callback type leaves out the continue its server takes
  # from `init`. One the store held nothing of asks for its definition here,
  # not in a continue: the meta `init` answers tells `Wardrik.Fleet.whereis/2`
  # whether it is gone.
  @dialyzer {:nowarn_function, init: 2}
  @impl DurableServer
  def init(%State{wake_only: true} = state, %{host: host} = info) do
    case Wardrik.Specs.current(Host.definitions(host), AgentAddress.agent(state.agent_id),
           host: host
         ) do
      {:ok, _spec} ->
        init(%{state | wake_only: false}, info)

      :none ->
        {:ok, State.hosted(state, host), {:continue, :gone},
         meta: Map.put(View.meta(state), :gone, true)}
    end
  end

  def init(%State{} = state, %{host: host}) do
    {:ok, State.hosted(state, host), {:continue, :open},
     meta: View.meta(state), permanent: true, sync_every_ms: @sync_every_ms}
  end

  # -- messages --------------------------------------------------------------

  # Every call and cast is something done, which puts off sleeping.
  @impl DurableServer
  def handle_call(request, from, state), do: called(request, from, touched(state))

  @impl DurableServer
  def handle_cast(request, state), do: told(request, touched(state))

  defp called({:configure, opts}, _from, state) do
    next = state |> State.configure(opts) |> redecide() |> arm_idle()
    {:reply, :ok, next, meta: View.meta(next), sync: true}
  end

  defp called({:checkpoint, checkpoint}, {pid, _tag}, state) do
    case State.checkpointed(state, pid, checkpoint) do
      {:ok, next} -> {:reply, :ok, next, meta: View.meta(next), sync: true}
      :stale -> {:reply, {:error, :not_the_running_turn}, state}
    end
  end

  defp called({:kept, history}, {pid, _tag}, state) do
    case State.kept(state, pid, history) do
      {:ok, next} -> {:reply, :ok, next, sync: true}
      :stale -> {:reply, {:error, :not_the_running_turn}, state}
    end
  end

  defp called(:clear, _from, state) do
    case State.clear(state) do
      {:ok, next, effects} ->
        next = perform(next, effects)
        {:reply, :ok, next, meta: View.meta(next), sync: true}

      {:error, :busy} ->
        {:reply, {:error, :busy}, state}
    end
  end

  defp called(:history, _from, state), do: {:reply, state.history, state}
  defp called(:status, _from, state), do: {:reply, View.status(state), state}
  defp called(:parked, _from, state), do: {:reply, State.waiting_on(state), state}
  defp called(:snapshot, _from, state), do: {:reply, View.snapshot(state), state}

  defp called({:decide, decisions, %Wardrik.Token{} = token}, _from, state) do
    ids = Enum.map(State.waiting_on(state), fn {call, _prompt} -> call.id end)

    cond do
      not State.decides?(state, token) ->
        {:reply, {:error, :forbidden}, state}

      ids == [] ->
        {:reply, {:error, :not_parked}, state}

      map_size(decisions) == 0 or not Enum.all?(Map.keys(decisions), &(&1 in ids)) ->
        {:reply, {:error, :stale_decision}, state}

      true ->
        case resume_turn(state, decisions, token.principal) do
          {:ok, next} -> {:reply, :ok, next, meta: View.meta(next), sync: true}
          {:error, next} -> {:reply, {:error, :unrecorded}, next}
        end
    end
  end

  defp told({:ask, %Message{} = message}, state) do
    {state, effects} = State.queue(state, message)

    state |> perform(effects) |> advance(sync: true)
  end

  defp told(:interrupt, state) do
    {state, effects} = state |> heed(&Credential.unsubscribe/2) |> State.interrupt()

    state |> perform(effects) |> advance(sync: true)
  end

  defp told({:resume, decisions, by}, state), do: decided(state, decisions, by)

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
      {:resume, run, turn, started_at} ->
        resume_parked(state, journaled(run), turn, started_at, decisions, by)

      :none ->
        {:ok, state}
    end
  end

  defp resume_parked(state, run, turn, started_at, decisions, by) do
    decided =
      for {call, _prompt} <- Turn.waiting(turn),
          Map.has_key?(decisions, call.id),
          do:
            Bus.Event.new(run.source, %Bus.CallDecided{
              call_id: call.id,
              decision: decisions[call.id],
              by: by
            })

    with {:ok, state} <- log_ahead(state, decided) do
      Enum.each(decided, &Bus.publish/1)
      {:ok, carry_on(state, run, turn, decisions, started_at)}
    end
  end

  defp carry_on(state, run, turn, decisions, started_at) do
    Bus.Event.emit(run.source, %Bus.TurnResumed{decisions: decisions})
    task = tethered(fn -> turn |> Turn.under(run) |> Turn.resume(decisions) end)

    state
    |> heed(&Credential.unsubscribe/2)
    |> State.resumed(task, run, turn, decisions, started_at)
  end

  # An agent hears that a credential is available while a call it parked
  # waits on it, and only then.
  defp heed(state, how) do
    Enum.each(State.awaited(state), fn %{ref: ref, owner: owner} -> how.(ref, owner) end)
    state
  end

  # Decisions are written to the log before they take effect, so none takes
  # effect unrecorded.
  defp log_ahead(state, events) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case Writer.append_ahead(Host.store(state.host), state.log, event) do
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
      Bus.Event.new(
        Source.root(state.agent_id),
        %Bus.AgentStarted{
          node: node(),
          status: View.status(state).state,
          generation: state.generation
        }
      )

    state = State.logged(state, Writer.open(Host.store(state.host), state.log, started))
    :ok = Bus.publish(started)
    {state, sync} = state |> heed(&Credential.subscribe/2) |> defined()

    state |> touched() |> arm_idle() |> advance(sync)
  end

  # Woken after it was forgotten: it goes without leaving anything behind.
  def handle_continue(:gone, state), do: {:stop, :delete, state}

  def handle_continue(:maybe_run, state) do
    case State.take(state) do
      {:run, run, messages, state} ->
        stay(start(state, run, messages))

      {:replay, run, checkpoint, state} ->
        stay(replay(state, run, checkpoint))

      {:resume, run, turn, decisions, state} ->
        stay(resume_again(state, run, turn, decisions))

      :none ->
        stay(state)
    end
  end

  # The definition the host keeps of it now, which may have changed while it
  # slept or ran on a node since lost. It is asked once the log is open, as a
  # parked turn its new hooks decide again writes to it.
  defp defined(state) do
    agent = AgentAddress.agent(state.agent_id)

    case Wardrik.Specs.current(Host.definitions(state.host), agent, host: state.host) do
      {:ok, spec} -> {state |> State.configure(Spec.options(spec)) |> redecide(), [sync: true]}
      :none -> {state, []}
    end
  end

  @impl DurableServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    if State.running?(state, ref) do
      Process.demonitor(ref, [:flush])
      state |> answered(result) |> touched() |> advance(sync: true)
    else
      stay(state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref),
    do: down(state, ref, reason)

  def handle_info({:kill, ref}, state) do
    case State.kill(state, ref) do
      {:kill, state, effects} -> state |> perform(effects) |> touched() |> advance(sync: true)
      :stale -> stay(state)
    end
  end

  # Word of a credential a call it parked waits on, which it approves.
  def handle_info(%Credential.Available{ref: ref, owner: owner, by: by}, state) do
    case State.awaiting(state, ref, owner) do
      [] -> {:noreply, state}
      ids -> state |> touched() |> decided(Map.new(ids, &{&1, :approve}), by)
    end
  end

  # Only the timer armed last counts.
  def handle_info({:idle, tag}, %State{idle_timer: {_timer, tag}} = state) do
    case State.idle(state, now()) do
      {:wait, ms} -> stay(arm_idle(state, ms))
      :never -> stay(%{state | idle_timer: nil})
      :sleep -> sleep(state)
    end
  end

  def handle_info({:idle, _tag}, state), do: stay(state)

  # The agent's own events, which it writes to its log and folds into what it
  # is doing.
  def handle_info(%Bus.Event{source: %{agent_id: id}} = event, %State{agent_id: id} = state) do
    {state, effects} = state |> log(event) |> State.heard(event)
    {:noreply, perform(state, effects)}
  end

  def handle_info(%Bus.Event{}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    stay(state)
  end

  # A write the log could not make is the writer's to report.
  defp log(state, event) do
    case Writer.append(Host.store(state.host), state.log, event) do
      {:ok, log} -> State.logged(state, log)
      {:error, _reason, log} -> State.logged(state, log)
    end
  end

  defp down(state, ref, reason) do
    if State.running?(state, ref) do
      Logger.error("Turn crashed: #{inspect(reason)}")
      state |> settle(State.failed(state, reason)) |> touched() |> advance(sync: true)
    else
      stay(state)
    end
  end

  # -- sleeping --------------------------------------------------------------

  defp touched(state), do: State.touched(state, now())

  defp now, do: System.monotonic_time(:millisecond)

  defp arm_idle(%State{idle_timeout: timeout} = state), do: arm_idle(state, timeout)

  defp arm_idle(%State{idle_timer: armed} = state, ms) do
    with {timer, _tag} <- armed, do: Process.cancel_timer(timer)

    case ms do
      :infinity ->
        %{state | idle_timer: nil}

      ms ->
        tag = make_ref()
        %{state | idle_timer: {Process.send_after(self(), {:idle, tag}, ms), tag}}
    end
  end

  # The stop is written to the log before the agent goes, since nothing of
  # this process hears its own event afterwards. A permanent stop is one the
  # fleet does not undo; the next caller wakes it.
  defp sleep(state) do
    stopped =
      Bus.Event.new(Source.root(state.agent_id), %Bus.AgentStopped{node: node(), reason: :idle})

    state = log(state, stopped)
    :ok = Bus.publish(stopped)

    {:stop, :permanent, %{state | idle_timer: nil}}
  end

  # -- returns ---------------------------------------------------------------

  # Every return republishes this agent's metadata, which is what `Wardrik.Fleet`
  # lists. `sync: true` writes the state to the store before returning.
  defp advance(state, opts) do
    {:noreply, state, {:continue, :maybe_run}, [meta: View.meta(state)] ++ opts}
  end

  defp stay(state, opts \\ []) do
    {:noreply, state, [meta: View.meta(state)] ++ opts}
  end

  # -- turns -----------------------------------------------------------------

  # The turn is made in its task, as making one may read what it begins with,
  # such as the files its tools tell the model first.
  defp start(state, run, messages) do
    run = run |> journaled() |> heard(messages)
    asked = Enum.map(messages, &User.new(Message.content(&1)))
    runtime = Host.runtime(state.host, Settings.key(state.config))
    history = state.history

    Bus.Event.emit(run.source, %Bus.TurnStarted{messages: messages})

    task =
      tethered(fn ->
        runtime |> Runtime.turn(run, history: history, asked: asked) |> Turn.run()
      end)

    State.started(state, task, run, Conversation.append(history, asked), System.monotonic_time())
  end

  defp replay(state, run, checkpoint) do
    run = journaled(run)
    Bus.Event.emit(run.source, %Bus.TurnStarted{messages: []})
    task = tethered(fn -> checkpoint |> Turn.under(run) |> Turn.recover() end)

    State.replayed(state, task, run, checkpoint, System.monotonic_time())
  end

  # Its decisions were logged when they were taken.
  defp resume_again(state, run, turn, decisions),
    do: carry_on(state, journaled(run), turn, decisions, System.monotonic_time())

  # Each turn hands its batches of tool calls to this process before running
  # them, which writes them down.
  defp journaled(run), do: %{run | journal: self()}

  defp heard(run, messages),
    do: %{
      run
      | labels: Enum.reduce(messages, run.labels, &Wardrik.Label.union(&2, &1.labels))
    }

  # A turn belongs to the agent that started it: one whose agent stopped, or
  # moved to another node, is killed rather than running a batch its successor
  # is replaying.
  defp tethered(fun) do
    agent = self()

    Task.Supervisor.async_nolink(Wardrik.Tasks.supervisor(), fn ->
      Wardrik.Tether.to(agent)
      fun.()
    end)
  end

  defp answered(state, turn) do
    case Turn.status(turn) do
      {:done, messages, labels} ->
        settle(state, State.settled(state, messages, labels))

      # A waiting turn is held as it is written down, with no run.
      :waiting ->
        state
        |> settle(State.parked(state, Turn.under(turn, nil)))
        |> heed(&Credential.subscribe/2)

      {:failed, reason} ->
        Logger.error("Turn failed: #{inspect(reason)}")
        settle(state, State.failed(state, reason))
    end
  end

  defp settle(_state, {next, effects}), do: perform(next, effects)

  # The one place a state's decisions become things that happen. Each effect is
  # carried out in the order it was produced, and an effect that has something
  # to record hands the state back.
  defp perform(state, effects), do: Enum.reduce(effects, state, &apply_effect/2)

  defp apply_effect({:emit, source, payload}, state) do
    Bus.Event.emit(source, payload)
    state
  end

  defp apply_effect({:ask_to_stop, pid}, state) do
    Signal.yield(pid)
    state
  end

  defp apply_effect({:stop_now, pid}, state) do
    Signal.interrupt(pid)
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

  # Sent from a task, so an asker woken from the store holds up nothing here.
  defp apply_effect({:send, agent, message}, state) do
    Task.Supervisor.start_child(Wardrik.Tasks.supervisor(), fn ->
      with {:error, :not_found} <- cast(agent, {:ask, message}, host: state.host),
           do: Logger.info("#{agent} is gone, so #{message.id} was not sent to it")
    end)

    state
  end

  defp apply_effect({:close_turn, run}, state) do
    %{agent_id: agent_id, log: %{head: through}} = state
    cutoff = DateTime.add(DateTime.utc_now(), -Log.retention_days(), :day)

    Task.Supervisor.start_child(Wardrik.Tasks.supervisor(), fn ->
      Wardrik.Ledger.forget(Host.store(run.host), agent_id, trace: run.source.trace.trace_id)

      Log.trim(Host.store(run.host), agent_id, through: through, before: cutoff)
    end)

    state
  end
end
