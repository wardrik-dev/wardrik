defmodule Tars.Agent.State do
  @moduledoc """
  What an agent is, as data, and every move it can make, as a function.

  `Tars.Agent` is a process wrapped around this. Nothing here spawns, sends,
  sleeps or emits: a transition takes a state and returns the next one
  alongside the `t:effect/0` values the process should carry out. That split is
  what makes the agent's behaviour testable without a process, and what will
  make its state dumpable when it becomes durable.

  ## One mode, not four flags

  An agent is idle, owed a turn, running one, or waiting on a person. That is a
  single field holding one of four shapes, each carrying exactly what that
  shape needs:

      %State{mode: :idle}
      %State{mode: :owed}
      %State{mode: %Running{task: task, scope: scope, started_at: at, stopping: nil}}
      %State{mode: %Waiting{turn: parked, scope: scope, started_at: at}}

  Because the data lives inside the mode rather than beside it, a whole class
  of states cannot be written down. There is no way to be running and waiting
  at once, to be stopping while idle, or to hold a scope with no turn under it.
  Nothing has to check for those, because nothing can produce them.

  Queued messages are held newest-first and reversed when a turn takes them, so
  appending is cheap and the order a caller sees is the order they were asked.

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
  alias Tars.Event
  alias Tars.LLM
  alias Tars.Scope
  alias Tars.Trace

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
    defstruct [:task, :scope, :started_at, :stopping]

    @typedoc "The task running the turn, the scope it runs under, and whether it is stopping."
    @type t() :: %__MODULE__{
            task: Task.t(),
            scope: Tars.Scope.t(),
            started_at: integer(),
            stopping: Tars.Agent.State.Stopping.t() | nil
          }
  end

  defmodule Waiting do
    @moduledoc "A turn held part way through, waiting on a person."

    @enforce_keys [:turn, :scope, :started_at]
    defstruct [:turn, :scope, :started_at]

    @typedoc "The parked turn, the scope it was running under, and when it began."
    @type t() :: %__MODULE__{
            turn: Tars.LLM.Turn.Parked.t(),
            scope: Tars.Scope.t(),
            started_at: integer()
          }
  end

  @scope_keys [:user, :org, :policy, :dispatch, :timeout]

  # Long enough for a streaming response to notice, short enough that a kill
  # switch feels like one. A tool mid-flight will not answer inside it.
  @default_grace 2_000

  @enforce_keys [:agent_id, :config, :context, :runner, :resumer, :scope_opts]
  defstruct [
    :agent_id,
    :config,
    :context,
    :runner,
    :resumer,
    :scope_opts,
    grace: @default_grace,
    mode: :idle,
    pending: []
  ]

  @doc "How long an interrupted turn is given to answer before it is killed."
  @spec default_grace() :: pos_integer()
  def default_grace, do: @default_grace

  @typedoc """
  What the agent is doing. Each shape carries its own data and nothing else's.

  `:owed` is an agent loaded from a dump taken mid-turn: nothing is running,
  and a turn is due against the context it already holds.
  """
  @type mode() :: :idle | :owed | Running.t() | Waiting.t()

  @typedoc """
  Runs one turn and reports how it ended, as `{module, function, args}`.

  Called with the scope and the context appended to `args`, so a host that
  needs to carry something of its own into the turn carries it there. It is an
  MFA rather than a function because an agent's state is written down and read
  back on another machine, and a closure is code rather than data.
  """
  @type runner() :: {module(), atom(), list()}

  @typedoc """
  Finishes a parked turn once its calls have been answered.

  Called with the scope, the parked turn and the decisions appended to `args`.
  """
  @type resumer() :: {module(), atom(), list()}

  @type t() :: %__MODULE__{
          agent_id: Event.Bus.agent_id(),
          config: LLM.Config.t(),
          context: Context.t(),
          runner: runner(),
          resumer: resumer(),
          scope_opts: keyword(),
          grace: pos_integer(),
          mode: mode(),
          pending: [String.t()]
        }

  @typedoc "An agent written down: what it is, what it was asked, and what it is waiting on."
  @type dumped() :: %{
          config: LLM.Config.dumped(),
          context: Context.t(),
          scope_opts: keyword(),
          grace: pos_integer(),
          pending: [String.t()],
          runner: runner(),
          resumer: resumer(),
          mode: :idle | :owed | {:waiting, LLM.Turn.Parked.t()}
        }

  @typedoc """
  Something the process should do on this state's behalf.

    * `{:emit, source, payload}` - publish an event
    * `{:ask_to_stop, pid}` - let a running turn finish its round, then return
    * `{:stop_now, pid}` - stop a running turn as soon as it can, mid-response
    * `{:arm_kill, ms, dropped}` - arm a kill after `ms`, then record it with `arm/4`
    * `{:cancel_kill, timer}` - a turn answered before its kill was needed
    * `{:shutdown, task}` - the kill fired; end the task now
  """
  @type effect() ::
          {:emit, Event.Source.t(), tuple()}
          | {:ask_to_stop, pid()}
          | {:stop_now, pid()}
          | {:arm_kill, pos_integer(), non_neg_integer()}
          | {:cancel_kill, reference()}
          | {:shutdown, Task.t()}

  @typedoc "What an interrupt stopped."
  @type stats() :: %{
          dropped: non_neg_integer(),
          kept: non_neg_integer(),
          resolution: :stopped | :killed | :idle | :abandoned,
          elapsed_ms: non_neg_integer()
        }

  @typedoc "Whether a turn is in flight, and how many messages are waiting behind it."
  @type status() :: %{state: :idle | :running | :parked, pending: non_neg_integer()}

  @doc "Builds the state an agent starts in. See `Tars.Agent.start_link/1` for the options."
  @spec new(keyword(), Event.Bus.agent_id()) :: t()
  def new(opts, agent_id) do
    %__MODULE__{
      agent_id: agent_id,
      config: Keyword.get(opts, :config, LLM.Config.new()),
      context: Keyword.get(opts, :context, Context.new()),
      runner: mfa!(Keyword.get(opts, :runner, {LLM.Turn, :run, []}), :runner),
      resumer: mfa!(Keyword.get(opts, :resumer, {LLM.Turn, :resume, []}), :resumer),
      scope_opts: Keyword.take(opts, @scope_keys),
      grace: Keyword.get(opts, :grace, @default_grace)
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
  @spec apply_runner(t(), Scope.t(), Context.t()) :: LLM.Turn.result()
  def apply_runner(%__MODULE__{runner: {module, function, args}}, %Scope{} = scope, context) do
    apply(module, function, args ++ [scope, context])
  end

  @doc "Finishes a parked turn with the resumer this agent was given."
  @spec apply_resumer(t(), Scope.t(), LLM.Turn.Parked.t(), map()) :: LLM.Turn.result()
  def apply_resumer(
        %__MODULE__{resumer: {module, function, args}},
        %Scope{} = scope,
        turn,
        decisions
      ) do
    apply(module, function, args ++ [scope, turn, decisions])
  end

  @doc """
  Writes this agent down as data.

  A turn in flight is recorded as `relaunch`, since its question is already the
  last thing in the context. See the module docs for the full mapping.
  """
  @spec dump(t()) :: dumped()
  def dump(%__MODULE__{} = state) do
    %{
      config: LLM.Config.dump(state.config),
      context: state.context,
      scope_opts: state.scope_opts,
      grace: state.grace,
      pending: state.pending,
      runner: state.runner,
      resumer: state.resumer,
      mode: at_rest(state.mode)
    }
  end

  # A task cannot cross a node, so a turn in flight comes back as one that is
  # owed. Everything else is written down as it stands.
  defp at_rest(%Waiting{turn: turn}), do: {:waiting, turn}
  defp at_rest(%Running{}), do: :owed
  defp at_rest(mode) when mode in [:idle, :owed], do: mode

  @doc """
  Rebuilds an agent from `dump/1`, resolving its config's tools on this node.

  Options override what was dumped, and are otherwise those of `new/2`.
  """
  @spec load(dumped(), keyword(), Event.Bus.agent_id()) :: t()
  def load(dumped, opts, agent_id) do
    config = LLM.Config.load(dumped.config)
    scope_opts = Keyword.merge(dumped.scope_opts, Keyword.take(opts, @scope_keys))

    opts =
      opts
      |> Keyword.put_new(:runner, dumped.runner)
      |> Keyword.put_new(:resumer, dumped.resumer)

    state = %{
      new(Keyword.merge(opts, config: config, context: dumped.context), agent_id)
      | scope_opts: scope_opts,
        grace: Keyword.get(opts, :grace, dumped.grace),
        pending: dumped.pending
    }

    %{state | mode: reopen(dumped.mode, state)}
  end

  # A new scope, since the dumped one would hold the old node's tools and a
  # deadline read from its monotonic clock.
  defp reopen({:waiting, %LLM.Turn.Parked{} = turn}, state) do
    %Waiting{turn: turn, scope: turn_scope(state), started_at: System.monotonic_time()}
  end

  defp reopen(mode, _state) when mode in [:idle, :owed], do: mode

  @doc "The scope a turn for this agent runs under."
  @spec turn_scope(t()) :: Scope.t()
  def turn_scope(%__MODULE__{} = state) do
    Scope.root(state.config, state.agent_id, [name: "turn"] ++ state.scope_opts)
  end

  @doc "What this agent is doing, and how much is queued behind it."
  @spec status(t()) :: status()
  def status(%__MODULE__{} = state) do
    %{state: activity(state.mode), pending: length(state.pending)}
  end

  defp activity(%Running{}), do: :running
  defp activity(%Waiting{}), do: :parked
  # A turn is due and will start on the next message: running, not idle.
  defp activity(:owed), do: :running
  defp activity(:idle), do: :idle

  @doc """
  What `Tars.Fleet` reports about this agent, republished on every transition.

  Replicated to every node, so it holds nothing private.
  """
  @spec meta(t()) :: %{status: atom(), pending: non_neg_integer(), waiting_on: [String.t()]}
  def meta(%__MODULE__{} = state) do
    %{
      status: activity(state.mode),
      pending: length(state.pending),
      waiting_on: Enum.map(waiting_on(state), fn {call, _prompt} -> call.name end)
    }
  end

  @doc "The calls a waiting agent needs answered, or `[]` when it is not waiting."
  @spec waiting_on(t()) :: [{Tars.Tool.call(), String.t()}]
  def waiting_on(%__MODULE__{mode: %Waiting{turn: turn}}), do: LLM.Turn.Parked.calls(turn)
  def waiting_on(%__MODULE__{}), do: []

  @doc """
  Queues a message, and says who to nudge.

  A message arriving mid-turn joins that turn rather than waiting for it, so a
  running turn is asked to stop at its next boundary and the queue it leaves
  behind starts the next one.
  """
  @spec queue(t(), String.t()) :: {t(), [effect()]}
  def queue(%__MODULE__{} = state, question) do
    {%{state | pending: [question | state.pending]}, nudge(state.mode)}
  end

  defp nudge(%Running{task: %Task{pid: pid}}), do: [{:ask_to_stop, pid}]
  defp nudge(_mode), do: []

  @doc """
  The questions a new turn should answer, and the state with them taken.

  `:none` when a turn is already in flight, when one is waiting on a person, or
  when nothing is queued. A waiting turn is still the current turn: anything
  behind it waits to be answered or abandoned rather than starting beside it.

  An agent that is `:owed` a turn runs one with no questions at all, against
  the context that already holds the question it was answering.
  """
  @spec take(t()) :: {:run, [String.t()], t()} | :none
  def take(%__MODULE__{mode: :owed} = state) do
    {:run, Enum.reverse(state.pending), %{state | pending: [], mode: :idle}}
  end

  def take(%__MODULE__{mode: :idle} = state) do
    case Enum.reverse(state.pending) do
      [] -> :none
      questions -> {:run, questions, %{state | pending: []}}
    end
  end

  def take(%__MODULE__{}), do: :none

  @doc "Records the turn a `take/1` led to, and the context it was given."
  @spec started(t(), Task.t(), Scope.t(), Context.t(), integer()) :: t()
  def started(%__MODULE__{} = state, task, %Scope{} = scope, %Context{} = context, started_at) do
    %{
      state
      | context: context,
        mode: %Running{task: task, scope: scope, started_at: started_at}
    }
  end

  @doc """
  Whether `task_ref` is the turn this agent is running.

  A result or a `:DOWN` from anything else belongs to a turn that was already
  settled or killed, and is not this state's business.
  """
  @spec running?(t(), reference()) :: boolean()
  def running?(%__MODULE__{mode: %Running{task: %Task{ref: ref}}}, task_ref), do: ref == task_ref
  def running?(%__MODULE__{}, _task_ref), do: false

  @doc """
  Settles a turn that answered, appending what it produced.

  A turn that answered while stopping reports what the interrupt kept rather
  than a plain finish, so a kill switch is never silent about what it caught.
  """
  @spec settled(t(), [ReqLLM.Message.t()]) :: {t(), [effect()]}
  def settled(%__MODULE__{mode: %Running{} = running} = state, messages) do
    {idle(%{state | context: Context.append(state.context, messages)}),
     [{:emit, running.scope.source, finish(running, messages)} | disarm(running)]}
  end

  defp finish(%Running{stopping: nil}, messages), do: {:turn_finished, messages}

  defp finish(%Running{stopping: stopping} = running, messages),
    do:
      {:turn_interrupted, stats(running.started_at, stopping.dropped, length(messages), :stopped)}

  @doc "Holds a turn that stopped to ask, and announces that it can be resumed."
  @spec parked(t(), LLM.Turn.Parked.t()) :: {t(), [effect()]}
  def parked(%__MODULE__{mode: %Running{} = running} = state, turn) do
    waiting = %Waiting{turn: turn, scope: running.scope, started_at: running.started_at}
    announcement = {:emit, running.scope.source, {:turn_parked, LLM.Turn.Parked.calls(turn)}}

    {%{state | mode: waiting}, [announcement | disarm(running)]}
  end

  @doc "Settles a turn that failed or crashed."
  @spec failed(t(), term()) :: {t(), [effect()]}
  def failed(%__MODULE__{mode: %Running{} = running} = state, reason) do
    {idle(state), [{:emit, running.scope.source, {:turn_failed, reason}} | disarm(running)]}
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

  def interrupt(%__MODULE__{mode: %Waiting{} = waiting} = state) do
    {drained, dropped} = drain(state)
    stats = stats(waiting.started_at, dropped, 0, :abandoned)

    {idle(drained), [{:emit, waiting.scope.source, {:turn_interrupted, stats}}]}
  end

  def interrupt(%__MODULE__{mode: mode} = state) when mode in [:idle, :owed] do
    {drained, dropped} = drain(state)
    stats = stats(nil, dropped, 0, :idle)

    {idle(drained), [{:emit, Event.Source.root(state.agent_id), {:turn_interrupted, stats}}]}
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

    {:kill, idle(state),
     [{:shutdown, running.task}, {:emit, running.scope.source, {:turn_interrupted, stats}}]}
  end

  def kill(%__MODULE__{}, _tag), do: :stale

  @doc """
  The turn a waiting agent should carry on with, given a person's decisions.

  `:none` when nothing is waiting, so answering an agent that is not asking is
  a no-op rather than an error.
  """
  @spec resume(t(), %{String.t() => LLM.Turn.Parked.decision()}) ::
          {:resume, Scope.t(), LLM.Turn.Parked.t(), integer()} | :none
  def resume(%__MODULE__{mode: %Waiting{} = waiting}, _decisions),
    do: {:resume, waiting.scope, waiting.turn, waiting.started_at}

  def resume(%__MODULE__{}, _decisions), do: :none

  @doc "Records the turn a `resume/2` led to, which carries on under the scope it parked in."
  @spec resumed(t(), Task.t(), Scope.t(), integer()) :: t()
  def resumed(%__MODULE__{} = state, task, %Scope{} = scope, started_at) do
    %{state | mode: %Running{task: task, scope: scope, started_at: started_at}}
  end

  defp idle(state), do: %{state | mode: :idle}

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
