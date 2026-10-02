defmodule Wardrik.Agent.State do
  @moduledoc """
  What an agent is, as data, and every move it can make, as a function.

  `Wardrik.Agent` is a process wrapped around this. Nothing here spawns, sends,
  sleeps or emits: a transition takes a state and returns the next one
  alongside the `t:effect/0` values the process should carry out. That split is
  what makes the agent's behaviour testable without a process, and what lets
  `dump/1` write it down.

  ## One mode, not four flags

  An agent is idle, owed a turn, running one, or waiting on a person. That is a
  single field holding one of four shapes, each carrying exactly what that
  shape needs:

      %State{mode: :idle}
      %State{mode: :owed}
      %State{mode: %Running{task: task, scope: scope, started_at: at, stopping: nil, parked: nil}}
      %State{mode: %Waiting{turn: parked, source: source, started_at: at}}

  Because the data lives inside the mode rather than beside it, a whole class
  of states cannot be written down. There is no way to be running and waiting
  at once, to be stopping while idle, or to hold a scope with no turn under it.
  Nothing has to check for those, because nothing can produce them.

  ## Written down

  `dump/1` and `load/1` carry an agent between nodes. A turn in flight is
  written as what it comes back as. A turn that has handed over a batch of
  tool calls comes back replaying from the last one, under the trace it began
  on, so the calls keep their ids; a fresh turn that has not is `:owed` and
  runs again against the context it already holds; a turn resumed from a park,
  and not checkpointed since, comes back resuming with the decisions it was
  given, so none is lost, and a `Wardrik.Ledger` answers for an approved call
  that had begun. A waiting turn keeps its source, and the events of its
  resumption land on the trace that parked. Its budget starts over when it is
  resumed.

  Who the work is for is read from the agent's key. How far its
  `Wardrik.Event.Log` has got is written down as a sequence number, from which
  the next owner looks for the head.

  Queued messages are held newest-first and reversed when a turn takes them, so
  appending is cheap and the order a caller sees is the order they were asked.

  ## Content from outside

  A turn that read content from outside leaves what it read in the history,
  so the agent is `tainted` from then on: every turn after it begins tainted
  (see `Wardrik.LLM.Turn`), and a gated tool's calls wait on a person as they
  would after reading it, until `clear/1` empties the history. A summary of
  the history keeps the mark, since it was written from what was read.

  ## Stopping is part of running

  An interrupt does not change mode. It marks the running turn as stopping and
  arms a kill, because a turn asked to stop is still a turn until it answers or
  is killed. `Stopping` therefore only exists inside `Running`.

  ## Why the kill is identified by a tag

  A kill is armed with a fresh `t:reference/0` that is stored in the same
  `Stopping` that armed it. `kill/2` only fires when the tag it is given is the
  tag the state is holding, so a timer that fired just as the turn answered,
  or one left over from an earlier interrupt, is refused by pattern match
  rather than by a guard someone has to remember to write.
  """

  alias ReqLLM.Context
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.Delegation
  alias Wardrik.Event
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Event.Source
  alias Wardrik.Fleet
  alias Wardrik.Hook
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Turn
  alias Wardrik.Scope
  alias Wardrik.Trace

  defmodule Stopping do
    @moduledoc "A running turn that has been asked to stop, and the kill armed behind it."

    @enforce_keys [:tag, :timer, :dropped]
    defstruct [:tag, :timer, :dropped]

    @typedoc "The kill's identity, its timer, and how many queued messages it discarded."
    @type t() :: %__MODULE__{tag: reference(), timer: reference(), dropped: non_neg_integer()}
  end

  defmodule Running do
    @moduledoc "A turn in flight, and everything that belongs to it."

    @enforce_keys [:task, :scope, :started_at]
    defstruct [:task, :scope, :started_at, :stopping, :parked, :decisions, :checkpoint]

    @typedoc """
    The task running the turn, the scope it runs under, whether it is
    stopping, the parked turn it resumed and the decisions it was resumed
    with, if it was, and the batch of tool calls it last handed over before
    running them.
    """
    @type t() :: %__MODULE__{
            task: Task.t(),
            scope: Wardrik.Scope.t(),
            started_at: integer(),
            stopping: Wardrik.Agent.State.Stopping.t() | nil,
            parked: Turn.t() | nil,
            decisions: %{String.t() => Turn.decision()} | nil,
            checkpoint: Turn.t() | nil
          }
  end

  defmodule Compacting do
    @moduledoc "History being summarised before the next turn, and whether that turn was owed."

    @enforce_keys [:task, :owed, :started_at]
    defstruct [:task, :owed, :started_at]

    @typedoc "The task summarising, whether a turn was owed when it began, and when."
    @type t() :: %__MODULE__{task: Task.t(), owed: boolean(), started_at: integer()}
  end

  defmodule Replaying do
    @moduledoc "A turn lost part way through, due to go on from its last checkpoint."

    @enforce_keys [:checkpoint, :source]
    defstruct [:checkpoint, :source]

    @typedoc "The checkpoint to go on from, and where the turn's events go."
    @type t() :: %__MODULE__{checkpoint: Turn.t(), source: Source.t()}
  end

  defmodule Resuming do
    @moduledoc "A parked turn lost after it was resumed, due to go on with the decisions it was given."

    @enforce_keys [:turn, :decisions, :source]
    defstruct [:turn, :decisions, :source]

    @typedoc "The parked turn, the decisions it resumes with, and where its events go."
    @type t() :: %__MODULE__{
            turn: Turn.t(),
            decisions: %{String.t() => Turn.decision()},
            source: Source.t()
          }
  end

  defmodule Waiting do
    @moduledoc "A turn held part way through, waiting on a person."

    @enforce_keys [:turn, :source, :started_at]
    defstruct [:turn, :source, :started_at]

    @typedoc "The parked turn, where its events go, and when it began."
    @type t() :: %__MODULE__{
            turn: Turn.t(),
            source: Source.t(),
            started_at: integer()
          }
  end

  # Long enough for a streaming response to notice, short enough that a kill
  # switch feels like one. A tool mid-flight will not answer inside it.
  @default_grace 2_000

  # How many message ids an agent remembers, so one sent again is taken once.
  @recent 256

  @enforce_keys [:agent_id, :config, :context, :runner, :resumer, :scope_opts, :log]
  defstruct [
    :generation,
    :agent_id,
    :log,
    :config,
    :context,
    :runner,
    :resumer,
    :scope_opts,
    replayer: {Turn, :replay, []},
    compaction_settled: false,
    grace: @default_grace,
    mode: :idle,
    pending: [],
    recent: [],
    outcome: nil,
    tainted: false,
    delegations: %Delegation{}
  ]

  @doc "How long an interrupted turn is given to answer before it is killed."
  @spec default_grace() :: pos_integer()
  def default_grace, do: @default_grace

  @typedoc """
  What the agent is doing. Each shape carries its own data and nothing else's.

  `:owed` is an agent loaded from a dump taken mid-turn: nothing is running,
  and a turn is due against the context it already holds.
  """
  @type mode() ::
          :idle
          | :owed
          | Running.t()
          | Waiting.t()
          | Replaying.t()
          | Resuming.t()
          | Compacting.t()

  @typedoc """
  Runs one turn and hands it back, as `{module, function, args}`.

  Called with the `Wardrik.LLM.Turn` to run appended to `args`, so a host that
  needs to carry something of its own into the turn carries it there. It is an
  MFA rather than a function because an agent's state is written down and read
  back on another machine, and a closure is code rather than data.
  """
  @type runner() :: {module(), atom(), list()}

  @typedoc """
  Finishes a waiting turn once its calls have been answered.

  Called with the turn, under the scope it resumes in, and the decisions
  appended to `args`.
  """
  @type resumer() :: {module(), atom(), list()}

  @type t() :: %__MODULE__{
          generation: String.t(),
          agent_id: Event.Bus.agent_id(),
          log: Writer.t(),
          config: Config.t(),
          context: Context.t(),
          runner: runner(),
          resumer: resumer(),
          scope_opts: keyword(),
          grace: pos_integer(),
          mode: mode(),
          pending: [Message.t()],
          recent: [String.t()],
          outcome: outcome(),
          tainted: boolean(),
          delegations: Delegation.t()
        }

  @typedoc "How the last turn ended, or `nil` before the first."
  @type outcome() :: nil | :ok | :failed | :interrupted

  @typedoc "An agent written down: what it is, what it was asked, and what it is waiting on."
  @type dumped() :: %{
          generation: String.t(),
          agent_id: Event.Bus.agent_id(),
          sequence: non_neg_integer(),
          config: Config.dumped(),
          context: Context.t(),
          scope_opts: keyword(),
          grace: pos_integer(),
          pending: [Message.t()],
          recent: [String.t()],
          runner: runner(),
          resumer: resumer(),
          outcome: outcome(),
          tainted: boolean(),
          mode:
            :idle
            | :owed
            | {:waiting, Turn.t(), Source.t()}
            | {:replaying, Turn.t(), Source.t()}
            | {:resuming, Turn.t(), %{String.t() => Turn.decision()}, Source.t()}
        }

  @typedoc """
  Something the process should do on this state's behalf.

    * `{:emit, source, payload}` - publish an event
    * `{:ask_to_stop, pid}` - let a running turn finish its round, then return
    * `{:stop_now, pid}` - stop a running turn as soon as it can, mid-response
    * `{:arm_kill, ms, dropped}` - arm a kill after `ms`, then record it with `arm/4`
    * `{:cancel_kill, timer}` - a turn answered before its kill was needed
    * `{:shutdown, task}` - the kill fired; end the task now
    * `{:close_turn, scope}` - a turn has ended for good: its ledger claims
      will never be read again, and the log can drop what has aged out
  """
  @type effect() ::
          {:emit, Source.t(), tuple()}
          | {:ask_to_stop, pid()}
          | {:stop_now, pid()}
          | {:arm_kill, pos_integer(), non_neg_integer()}
          | {:cancel_kill, reference()}
          | {:shutdown, Task.t()}
          | {:close_turn, Scope.t()}

  @typedoc "What an interrupt stopped."
  @type stats() :: %{
          dropped: non_neg_integer(),
          kept: non_neg_integer(),
          resolution: :stopped | :killed | :idle | :abandoned,
          elapsed_ms: non_neg_integer()
        }

  @typedoc "Whether a turn is in flight, and how many messages are waiting behind it."
  @type status() :: %{
          state: :idle | :running | :parked,
          pending: non_neg_integer(),
          model: term()
        }

  @typedoc """
  What the fleet shows for an agent: what it is doing, how much waits behind
  it, the calls it is waiting on, how many delegations the current turn has
  started and still has going, and how the last turn ended.
  """
  @type meta() :: %{
          status: :idle | :running | :parked,
          pending: non_neg_integer(),
          waiting_on: [String.t()],
          delegations: %{active: non_neg_integer(), total: non_neg_integer()},
          outcome: outcome()
        }

  @doc """
  Builds the state an agent starts in. See `Wardrik.Agent.initial_state/2` for
  the options.

  `agent_id` is the agent's fleet key, and names who the work is for.
  """
  @spec new(keyword(), Event.Bus.agent_id()) :: t()
  def new(opts, agent_id) do
    {org, user, _name} = Fleet.parse(agent_id)

    %__MODULE__{
      generation: generation(),
      agent_id: agent_id,
      log: Writer.new(agent_id),
      config: Keyword.get(opts, :config, Config.new()),
      context: Keyword.get(opts, :context, Context.new()),
      runner: mfa!(Keyword.get(opts, :runner, {Turn, :run, []}), :runner),
      resumer: mfa!(Keyword.get(opts, :resumer, {Turn, :resume, []}), :resumer),
      replayer: mfa!(Keyword.get(opts, :replayer, {Turn, :replay, []}), :replayer),
      scope_opts: [user: user, org: org] ++ Keyword.take(opts, Scope.seams()),
      grace: Keyword.get(opts, :grace, @default_grace)
    }
  end

  @doc """
  The same agent with the config and seams in `opts`, for the turns it starts
  from now on. A turn already running keeps the scope it began under, and a
  parked one is resumed under the new seams.

  `:config` replaces the config when given. The seams in `opts`, of
  `Wardrik.Scope.seams/0`, replace every seam the agent had, so one left out is
  one the agent no longer has. Who the work is for stays with the key.
  """
  @spec configure(t(), keyword()) :: t()
  def configure(%__MODULE__{} = state, opts) do
    who = Keyword.take(state.scope_opts, [:user, :org])

    %{
      state
      | config: Keyword.get(opts, :config, state.config),
        scope_opts: who ++ Keyword.take(opts, Scope.seams())
    }
  end

  defp mfa!({module, function, args}, _key)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {module, function, args}

  defp mfa!(other, key) do
    raise ArgumentError,
          ":#{key} must be {module, function, args}, got: #{inspect(other)}. " <>
            "An agent's state is written down and read back elsewhere, so a function cannot be one."
  end

  @doc "Runs a turn with the runner this agent was given."
  @spec apply_runner(t(), Scope.t(), Context.t()) :: Turn.t()
  def apply_runner(%__MODULE__{runner: {module, function, args}}, %Scope{} = scope, context) do
    apply(module, function, args ++ [Turn.new(scope, context)])
  end

  @doc "Finishes a parked turn with the resumer this agent was given."
  @spec apply_resumer(t(), Scope.t(), Turn.t(), map()) :: Turn.t()
  def apply_resumer(
        %__MODULE__{resumer: {module, function, args}},
        %Scope{} = scope,
        turn,
        decisions
      ) do
    apply(module, function, args ++ [Turn.under(turn, scope), decisions])
  end

  @doc "Carries on a lost turn from where its journal last had it, with the replayer this agent was given."
  @spec apply_replayer(t(), Scope.t(), Turn.t()) :: Turn.t()
  def apply_replayer(
        %__MODULE__{replayer: {module, function, args}},
        %Scope{} = scope,
        checkpoint
      ) do
    apply(module, function, args ++ [Turn.under(checkpoint, scope)])
  end

  @doc "Writes this agent down as data. See the module docs for what a turn in flight becomes."
  @spec dump(t()) :: dumped()
  def dump(%__MODULE__{} = state) do
    state
    |> Map.from_struct()
    |> Map.drop([:delegations, :log])
    |> Map.merge(%{
      config: Config.dump(state.config),
      mode: at_rest(state.mode),
      sequence: state.log.head
    })
  end

  defp at_rest(%Waiting{turn: turn, source: source}), do: {:waiting, turn, source}
  defp at_rest(%Compacting{owed: true}), do: :owed
  defp at_rest(%Compacting{owed: false}), do: :idle

  defp at_rest(%Replaying{checkpoint: checkpoint, source: source}),
    do: {:replaying, checkpoint, source}

  # A checkpoint is the furthest a turn got, past any park it was resumed from.
  defp at_rest(%Running{checkpoint: %Turn{} = checkpoint, scope: scope}),
    do: {:replaying, checkpoint, scope.source}

  defp at_rest(%Resuming{turn: turn, decisions: decisions, source: source}),
    do: {:resuming, turn, decisions, source}

  defp at_rest(%Running{parked: nil}), do: :owed

  defp at_rest(%Running{parked: turn, decisions: decisions, scope: scope}),
    do: {:resuming, turn, decisions, scope.source}

  defp at_rest(mode) when mode in [:idle, :owed], do: mode

  @doc "Reads an agent back from `dump/1`, with the tools this node can build."
  @spec load(dumped()) :: t()
  def load(%{agent_id: agent_id, config: config, mode: mode} = dumped) do
    {sequence, dumped} = Map.pop(dumped, :sequence, 0)

    dumped =
      dumped
      |> Map.put_new_lazy(:generation, &generation/0)
      |> Map.update(:pending, [], &Enum.map(&1, fn message -> queued(message) end))
      |> Map.put(:log, Writer.new(agent_id, sequence))

    struct!(__MODULE__, %{dumped | config: Config.load(config), mode: reopen(mode)})
  end

  # An agent written down before messages had ids queued their text alone.
  defp queued(%Message{} = message), do: message
  defp queued(text) when is_binary(text), do: Message.new(text)

  defp generation, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @doc """
  An atomic attachment snapshot; generation survives restarts but not
  deletion. Carries the current turn's delegations, so a client attaching
  mid-turn sees the work already under way, and the last sequence its log
  has written, so the client can follow the log from there.
  """
  @spec snapshot(t()) :: Snapshot.t()
  def snapshot(state) do
    %Snapshot{
      generation: state.generation,
      status: status(state),
      context: state.context,
      parked: waiting_on(state),
      trace_id: trace_id(state.mode),
      delegations: state.delegations,
      outcome: state.outcome,
      sequence: state.log.head
    }
  end

  defp trace_id(%Running{scope: scope}), do: scope.source.trace.trace_id
  defp trace_id(%Waiting{source: source}), do: source.trace.trace_id
  defp trace_id(%Replaying{source: source}), do: source.trace.trace_id
  defp trace_id(%Resuming{source: source}), do: source.trace.trace_id
  defp trace_id(_mode), do: nil

  defp reopen({:waiting, turn, source}) do
    %Waiting{turn: turn, source: source, started_at: System.monotonic_time()}
  end

  defp reopen({:replaying, checkpoint, source}),
    do: %Replaying{checkpoint: checkpoint, source: source}

  defp reopen({:resuming, turn, decisions, source}),
    do: %Resuming{turn: turn, decisions: decisions, source: source}

  defp reopen(mode) when mode in [:idle, :owed], do: mode

  @doc """
  Whether the turn this agent waits on parked under hooks other than the ones
  it has now, by `Wardrik.Hook.revision/1`.
  """
  @spec stale?(t()) :: boolean()
  def stale?(%__MODULE__{mode: %Waiting{turn: %Turn{revision: revision}}} = state),
    do: revision != Hook.revision(Keyword.get(state.scope_opts, :hooks) || [])

  def stale?(%__MODULE__{}), do: false

  @doc "The scope a turn for this agent runs under, tainted where its history is."
  @spec turn_scope(t()) :: Scope.t()
  def turn_scope(%__MODULE__{} = state) do
    scope = Scope.root(state.config, state.agent_id, [name: "turn"] ++ state.scope_opts)
    %{scope | tainted: state.tainted}
  end

  @doc "What this agent is doing, how much is queued behind it, and the model it runs."
  @spec status(t()) :: status()
  def status(%__MODULE__{} = state) do
    %{
      state: activity(state.mode),
      pending: length(state.pending),
      model: state.config.model_spec
    }
  end

  defp activity(%Running{}), do: :running
  defp activity(%Waiting{}), do: :parked
  defp activity(%Replaying{}), do: :running
  defp activity(%Resuming{}), do: :running
  defp activity(%Compacting{}), do: :running
  # A turn is due and will start on the next message: running, not idle.
  defp activity(:owed), do: :running
  defp activity(:idle), do: :idle

  @doc """
  What `Wardrik.Fleet` reports about this agent, republished on every transition.

  Replicated to every node, so it holds nothing private.
  """
  @spec meta(t()) :: meta()
  def meta(%__MODULE__{} = state) do
    %{state: activity, pending: pending} = status(state)

    %{
      status: activity,
      pending: pending,
      waiting_on: Enum.map(waiting_on(state), fn {call, _prompt} -> call.name end),
      delegations: Delegation.summary(state.delegations),
      outcome: state.outcome
    }
  end

  @doc """
  Folds one of this agent's own events into what it knows of the current
  turn's delegations. Only `:lifecycle` events shape them.
  """
  @spec observe(t(), Event.t()) :: t()
  def observe(%__MODULE__{} = state, %Event{} = event) do
    if Event.level(Event.type(event)) == :lifecycle,
      do: %{state | delegations: Delegation.fold(state.delegations, event)},
      else: state
  end

  @doc "Records how far this agent's log has got."
  @spec logged(t(), Writer.t()) :: t()
  def logged(%__MODULE__{} = state, %Writer{} = log), do: %{state | log: log}

  @doc "The calls a waiting agent needs answered, or `[]` when it is not waiting."
  @spec waiting_on(t()) :: [{Wardrik.Tool.call(), String.t()}]
  def waiting_on(%__MODULE__{mode: %Waiting{turn: turn}}), do: Turn.waiting(turn)
  def waiting_on(%__MODULE__{}), do: []

  @doc """
  Queues a message, announces it, and says who to nudge.

  A message arriving mid-turn joins that turn rather than waiting for it, so a
  running turn is asked to stop at its next boundary and the queue it leaves
  behind starts the next one. A message whose id was among the last
  #{@recent} queued is the same message sent again, and changes nothing.
  """
  @spec queue(t(), Message.t()) :: {t(), [effect()]}
  def queue(%__MODULE__{} = state, %Message{id: id} = message) do
    if id in state.recent do
      {state, []}
    else
      queued = %{
        state
        | pending: [message | state.pending],
          recent: Enum.take([id | state.recent], @recent)
      }

      {queued,
       [{:emit, Source.root(state.agent_id), {:message_queued, message}} | nudge(state.mode)]}
    end
  end

  defp nudge(%Running{task: %Task{pid: pid}}), do: [{:ask_to_stop, pid}]
  defp nudge(_mode), do: []

  @doc """
  The messages a new turn should answer, and the state with them taken.

  `:none` when a turn is already in flight, when one is waiting on a person, or
  when nothing is queued. A waiting turn is still the current turn: anything
  behind it waits to be answered or abandoned rather than starting beside it.

  An agent that is `:owed` a turn runs one with no questions at all, against
  the context that already holds the question it was answering. One replaying
  a turn answers `{:replay, scope, checkpoint, state}`: the turn goes on from
  its checkpoint, under the trace it began on. One resuming a parked turn
  answers `{:resume, scope, turn, decisions, state}`: the turn goes on with
  the decisions it was given, under the trace that parked.

  Before a turn, a history that has outgrown its config's `Wardrik.Compaction`
  answers `{:compact, scope, state}`: the history is summarised first, see
  `compacting/3` and `compacted/2`, and the turn is taken after. Once a
  compaction has run, whatever it managed, none runs again before that turn
  starts, so a summary that leaves the history over its threshold still lets
  the turn through.
  """

  @spec take(t()) ::
          {:run, [Message.t()], t()}
          | {:compact, Scope.t(), t()}
          | {:replay, Scope.t(), Turn.t(), t()}
          | {:resume, Scope.t(), Turn.t(), %{String.t() => Turn.decision()}, t()}
          | :none
  def take(%__MODULE__{mode: %Replaying{checkpoint: checkpoint, source: source}} = state) do
    {:replay, %{turn_scope(state) | source: source}, checkpoint, state}
  end

  def take(%__MODULE__{mode: %Resuming{} = resuming} = state) do
    {:resume, %{turn_scope(state) | source: resuming.source}, resuming.turn, resuming.decisions,
     state}
  end

  def take(%__MODULE__{mode: mode} = state) when mode in [:idle, :owed] do
    cond do
      mode == :idle and state.pending == [] ->
        :none

      compaction_due?(state) ->
        {:compact, turn_scope(state), state}

      true ->
        {:run, Enum.reverse(state.pending),
         %{state | pending: [], mode: :idle, compaction_settled: false}}
    end
  end

  def take(%__MODULE__{}), do: :none

  defp compaction_due?(%__MODULE__{compaction_settled: true}), do: false

  defp compaction_due?(%__MODULE__{config: config, context: context}),
    do: Wardrik.Compaction.split(config.compaction, context, config.model_spec) != :keep

  @doc "Records the task summarising this agent's history, which a `{:compact, ...}` from `take/1` led to."
  @spec compacting(t(), Task.t(), integer()) :: t()
  def compacting(%__MODULE__{mode: mode} = state, task, started_at) when mode in [:idle, :owed],
    do: %{state | mode: %Compacting{task: task, owed: mode == :owed, started_at: started_at}}

  @doc "Whether `task_ref` is the compaction this agent is running."
  @spec compacting?(t(), reference()) :: boolean()
  def compacting?(%__MODULE__{mode: %Compacting{task: %Task{ref: ref}}}, task_ref),
    do: ref == task_ref

  def compacting?(%__MODULE__{}, _task_ref), do: false

  @doc """
  Settles a compaction with what `Wardrik.Compaction.run/2` answered: the
  summarised history in place of the old one, or the old one as it was, and
  the turn that was waiting on it due either way.
  """
  @spec compacted(t(), term()) :: {t(), [effect()]}
  def compacted(%__MODULE__{mode: %Compacting{owed: owed}} = state, result) do
    mode = if owed, do: :owed, else: :idle

    case result do
      {:ok, %Context{} = context, stats} ->
        {%{state | mode: mode, context: context, compaction_settled: true},
         [{:emit, turn_scope(state).source, {:context_compacted, stats}}]}

      _kept_or_failed ->
        {%{state | mode: mode, compaction_settled: true}, []}
    end
  end

  @doc "Records the turn a `take/1` led to, and the context it was given."
  @spec started(t(), Task.t(), Scope.t(), Context.t(), integer()) :: t()
  def started(%__MODULE__{} = state, task, %Scope{} = scope, %Context{} = context, started_at) do
    %{
      state
      | context: context,
        mode: %Running{task: task, scope: scope, started_at: started_at}
    }
  end

  @doc "Records the turn a `{:replay, ...}` from `take/1` led to."
  @spec replayed(t(), Task.t(), Scope.t(), Turn.t(), integer()) :: t()
  def replayed(%__MODULE__{} = state, task, %Scope{} = scope, checkpoint, started_at) do
    %{
      state
      | mode: %Running{task: task, scope: scope, started_at: started_at, checkpoint: checkpoint}
    }
  end

  @doc """
  Records the batch of tool calls the running turn is about to run, so a turn
  lost from here goes on from it. `:stale` when `pid` is not the running turn.
  """
  @spec checkpointed(t(), pid(), Turn.t()) :: {:ok, t()} | :stale
  def checkpointed(
        %__MODULE__{mode: %Running{task: %Task{pid: pid}} = running} = state,
        pid,
        checkpoint
      ),
      do: {:ok, %{state | mode: %{running | checkpoint: checkpoint}}}

  def checkpointed(%__MODULE__{}, _pid, _checkpoint), do: :stale

  @doc """
  Whether `task_ref` is the turn this agent is running.

  A result or a `:DOWN` from anything else belongs to a turn that was already
  settled or killed, and is not this state's business.
  """
  @spec running?(t(), reference()) :: boolean()
  def running?(%__MODULE__{mode: %Running{task: %Task{ref: ref}}}, task_ref), do: ref == task_ref
  def running?(%__MODULE__{}, _task_ref), do: false

  @doc """
  Settles a turn that answered, appending what it produced, and `tainted`
  where it read content from outside.

  A turn that answered while stopping reports what the interrupt kept rather
  than a plain finish, so a kill switch is never silent about what it caught.
  """
  @spec settled(t(), [ReqLLM.Message.t()], boolean()) :: {t(), [effect()]}
  def settled(%__MODULE__{mode: %Running{} = running} = state, messages, tainted) do
    outcome = if running.stopping, do: :interrupted, else: :ok

    state = %{
      state
      | context: Context.append(state.context, messages),
        outcome: outcome,
        tainted: state.tainted or tainted
    }

    {idle(state),
     [{:emit, running.scope.source, finish(running, messages)}, close(running.scope)] ++
       disarm(running)}
  end

  defp finish(%Running{stopping: nil}, messages), do: {:turn_finished, messages}

  defp finish(%Running{stopping: stopping} = running, messages),
    do:
      {:turn_interrupted, stats(running.started_at, stopping.dropped, length(messages), :stopped)}

  @doc """
  Empties the history, and with it the mark of content from outside, keeping
  everything else. `{:error, :busy}` unless the agent is idle: a turn running,
  owed, waiting on a person or being compacted holds the history it began
  with.
  """
  @spec clear(t()) :: {:ok, t(), [effect()]} | {:error, :busy}
  def clear(%__MODULE__{mode: :idle} = state) do
    dropped = length(state.context.messages)

    {:ok, %{state | context: Context.new(), tainted: false, compaction_settled: false},
     [{:emit, Source.root(state.agent_id), {:context_cleared, dropped}}]}
  end

  def clear(%__MODULE__{}), do: {:error, :busy}

  @doc "Holds a turn that stopped to ask, and announces that it can be resumed."
  @spec parked(t(), Turn.t()) :: {t(), [effect()]}
  def parked(%__MODULE__{mode: %Running{} = running} = state, turn) do
    waiting = %Waiting{turn: turn, source: running.scope.source, started_at: running.started_at}
    announcement = {:emit, running.scope.source, {:turn_parked, Turn.waiting(turn)}}

    {%{state | mode: waiting}, [announcement | disarm(running)]}
  end

  @doc "Settles a turn that failed or crashed."
  @spec failed(t(), term()) :: {t(), [effect()]}
  def failed(%__MODULE__{mode: %Running{} = running} = state, reason) do
    {idle(%{state | outcome: :failed}),
     [{:emit, running.scope.source, {:turn_failed, reason}}, close(running.scope)] ++
       disarm(running)}
  end

  # A turn that answered before its kill was needed leaves the timer behind; it
  # is cancelled rather than left to fire into a state that has moved on.
  defp disarm(%Running{stopping: nil}), do: []
  defp disarm(%Running{stopping: %Stopping{timer: timer}}), do: [{:cancel_kill, timer}]

  @doc """
  Stops whatever is happening and discards whatever is queued.

  A running turn is asked to stop and a kill is armed behind it. A waiting turn
  is abandoned outright, which is the only way to be rid of one without
  answering it. An idle agent reports that there was nothing to stop.

  Interrupting a turn that is already stopping changes nothing: the kill that
  is armed is the one that will fire.
  """
  @spec interrupt(t()) :: {t(), [effect()]}
  def interrupt(%__MODULE__{mode: %Running{stopping: %Stopping{}}} = state), do: {state, []}

  def interrupt(%__MODULE__{mode: %Running{} = running} = state) do
    {drained, dropped} = drain(state)

    {drained, [{:stop_now, running.task.pid}, {:arm_kill, state.grace, dropped}]}
  end

  def interrupt(%__MODULE__{mode: %Compacting{task: task} = compacting} = state) do
    {drained, dropped} = drain(state)
    stats = stats(compacting.started_at, dropped, 0, :stopped)

    {idle(%{drained | outcome: :interrupted, compaction_settled: true}),
     [{:shutdown, task}, {:emit, turn_scope(state).source, {:turn_interrupted, stats}}]}
  end

  def interrupt(%__MODULE__{mode: %mode{source: source}} = state)
      when mode in [Replaying, Resuming] do
    {drained, dropped} = drain(state)

    {idle(%{drained | outcome: :interrupted}),
     [
       {:emit, source, {:turn_interrupted, stats(nil, dropped, 0, :abandoned)}},
       close(%{turn_scope(state) | source: source})
     ]}
  end

  def interrupt(%__MODULE__{mode: %Waiting{} = waiting} = state) do
    {drained, dropped} = drain(state)
    stats = stats(waiting.started_at, dropped, 0, :abandoned)

    {idle(%{drained | outcome: :interrupted}),
     [
       {:emit, waiting.source, {:turn_interrupted, stats}},
       close(%{turn_scope(state) | source: waiting.source})
     ]}
  end

  def interrupt(%__MODULE__{mode: mode} = state) when mode in [:idle, :owed] do
    {drained, dropped} = drain(state)
    stats = stats(nil, dropped, 0, :idle)

    {idle(drained), [{:emit, Source.root(state.agent_id), {:turn_interrupted, stats}}]}
  end

  defp drain(state), do: {%{state | pending: []}, length(state.pending)}

  @doc """
  Records the kill an `{:arm_kill, _}` effect armed.

  The tag is how `kill/2` recognises its own timer, so it is stored beside it
  rather than inferred from anything else.
  """
  @spec arm(t(), reference(), reference(), non_neg_integer()) :: t()
  def arm(%__MODULE__{mode: %Running{} = running} = state, tag, timer, dropped) do
    stopping = %Stopping{tag: tag, timer: timer, dropped: dropped}

    %{state | mode: %{running | stopping: stopping}}
  end

  @doc """
  Fires the kill armed under `tag`, or refuses a tag that is not the live one.

  `:stale` covers every timer that outlived what armed it: the turn answered,
  was abandoned, or a later interrupt armed a kill of its own.
  """
  @spec kill(t(), reference()) :: {:kill, t(), [effect()]} | :stale
  def kill(%__MODULE__{mode: %Running{stopping: %Stopping{tag: tag}} = running} = state, tag) do
    stats = stats(running.started_at, running.stopping.dropped, 0, :killed)

    {:kill, idle(%{state | outcome: :interrupted}),
     [
       {:shutdown, running.task},
       {:emit, running.scope.source, {:turn_interrupted, stats}},
       close(running.scope)
     ]}
  end

  def kill(%__MODULE__{}, _tag), do: :stale

  @doc """
  The turn a waiting agent should carry on with, and the scope to run it under:
  this node's tools, a fresh budget, and the source that parked.

  `:none` when nothing is waiting.
  """
  @spec resume(t()) :: {:resume, Scope.t(), Turn.t(), integer()} | :none
  def resume(%__MODULE__{mode: %Waiting{} = waiting} = state) do
    scope = %{turn_scope(state) | source: waiting.source}

    {:resume, scope, waiting.turn, waiting.started_at}
  end

  def resume(%__MODULE__{}), do: :none

  @doc """
  Records the turn a `resume/1`, or a `{:resume, ...}` from `take/1`, led to:
  the park it came from and the decisions it was resumed with.
  """
  @spec resumed(t(), Task.t(), Scope.t(), Turn.t(), %{String.t() => Turn.decision()}, integer()) ::
          t()
  def resumed(%__MODULE__{} = state, task, %Scope{} = scope, turn, decisions, started_at) do
    running = %Running{
      task: task,
      scope: scope,
      started_at: started_at,
      parked: turn,
      decisions: decisions
    }

    %{state | mode: running}
  end

  defp idle(state), do: %{state | mode: :idle}

  defp close(%Scope{} = scope), do: {:close_turn, scope}

  # A turn that never started has no clock to read, so it reports no time.
  defp stats(started_at, dropped, kept, resolution) do
    %{
      dropped: dropped,
      kept: kept,
      resolution: resolution,
      elapsed_ms: elapsed_ms(started_at)
    }
  end

  defp elapsed_ms(nil), do: 0
  defp elapsed_ms(started_at), do: Trace.elapsed_ms(started_at)
end
