defmodule Wardrik.Agent.State do
  @moduledoc """
  What an agent is, as data, and every move it can make, as a function.

  `Wardrik.Agent` is a process wrapped around this. Nothing here spawns, sends,
  sleeps or emits: a transition takes a state and returns the next one
  alongside the `t:effect/0` values the process should carry out. That split is
  what makes the agent's behaviour testable without a process, and what lets
  `Wardrik.Agent.State.Stored` write it down.

  ## One mode, not four flags

  An agent is idle, due a turn, running one, or waiting on a person. That is a
  single field holding one of four shapes, each carrying exactly what that
  shape needs:

      %State{mode: :idle}
      %State{mode: %Due{recovery: :owed, source: nil, sender: maria}}
      %State{mode: %Running{task: task, run: run, started_at: at, stopping: nil, recovery: :owed}}
      %State{mode: %Waiting{turn: parked, source: source, sender: maria, started_at: at}}

  Because the data lives inside the mode rather than beside it, a whole class
  of states cannot be written down. There is no way to be running and waiting
  at once, to be stopping while idle, or to hold a run with no turn under it.
  Nothing has to check for those, because nothing can produce them.

  ## Written down

  `Wardrik.Agent.State.Stored` carries an agent between nodes. A turn in
  flight is written as the `Due` turn it comes back as, which it holds as its
  `recovery` from the moment it starts. A turn that has handed over a batch
  of tool calls comes back replaying from the last one, under the trace it
  began on, so the calls keep their ids; a fresh turn that has not is owed,
  and runs again against the history it already holds; a turn resumed from a
  park, and not checkpointed since, comes back resuming with the decisions it
  was given, so none is lost, and the `Wardrik.Ledger` answers for an approved
  call that had begun. A waiting turn keeps its source, and the events of its
  resumption land on the trace that parked. Its budget starts over when it is
  resumed. `Wardrik.Agent.State.View` is what the agent shows of itself.

  Who the work is for is read from the agent's key. How far its
  `Wardrik.Event.Log` has got is written down as a sequence number, from which
  the next owner looks for the head.

  Queued messages are held newest-first and reversed when a turn takes them, so
  appending is cheap and the order a caller sees is the order they were asked.

  ## One sender a turn

  A turn answers the messages of one sender, and its run names them as
  `Wardrik.Run`'s `:sender`, so what it does for someone is done
  as them: `take/1` takes the oldest queued message and those after it from
  the same sender, and leaves the rest for the turns after. A message from
  the running turn's sender joins that turn; one from anybody else waits for
  it to end. A turn due or waiting keeps its sender, and goes on as theirs.

  ## What the history holds

  A turn leaves what it read in the history, and a message what it says, so
  the agent carries their `Wardrik.Label`s from then on: every turn after
  begins with them (see `Wardrik.LLM.Turn`), and its hooks weigh them as they
  would have then, until `clear/1` empties the history. A summary of the
  history keeps them, since it was written from what was read.

  A turn may hand the agent a history it rewrote as it began, a summary in
  place of its older part, say, which is the agent's from then on: `kept/3`
  records it, so a turn that parks or is lost keeps it too.

  ## Who the turn answers

  A message may name agents its answer goes to (see `Wardrik.Agent.Message`).
  A turn that takes it owes each of them an answer, held in `answering` from
  its start, written down with the agent, and paid as the turn ends: the
  turn's answer, holding the labels the turn ended with, where it finishes;
  a word that it failed, or that it stopped, where it does not. A message
  dropped from the queue unanswered is told it stopped too. Each is a
  `{:send, id, message}` effect, a message from this agent under an id made
  from the one it answers, so one sent again is taken once.

  ## Stopping is part of running

  An interrupt does not change mode. It marks the running turn as stopping and
  arms a kill, because a turn asked to stop is still a turn until it answers or
  is killed. `Stopping` therefore only exists inside `Running`.

  ## The kill names its turn

  A kill is armed for the running turn's task, and `kill/2` fires only while
  that task is the one running and stopping, so a timer that fired just as
  the turn answered, or one armed for a turn before it, is refused by pattern
  match rather than by a guard someone has to remember to write.
  """

  alias Wardrik.Agent.Activity
  alias Wardrik.Agent.Message
  alias Wardrik.Conversation
  alias Wardrik.Event
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Event.Source
  alias Wardrik.LLM.Config
  alias Wardrik.Principal
  alias Wardrik.Run
  alias Wardrik.Trace
  alias Wardrik.Turn

  defmodule Stopping do
    @moduledoc "A running turn that has been asked to stop, and the kill armed behind it."

    @enforce_keys [:timer, :dropped]
    defstruct [:timer, :dropped]

    @typedoc "The kill's timer, and how many queued messages it discarded."
    @type t() :: %__MODULE__{timer: reference(), dropped: non_neg_integer()}
  end

  defmodule Running do
    @moduledoc "A turn in flight, and everything that belongs to it."

    @enforce_keys [:task, :run, :started_at, :recovery]
    defstruct [:task, :run, :started_at, :stopping, :recovery]

    @typedoc """
    What the turn comes back as if it is lost: `:owed`, run again against
    the history the agent holds; `{:replaying, checkpoint}`, carried on from
    the batch of tool calls it last handed over; or `{:resuming, parked,
    decisions}`, the park it resumed, with the decisions it was resumed with.
    """
    @type recovery() ::
            :owed
            | {:replaying, Turn.t()}
            | {:resuming, Turn.t(), Turn.decisions()}

    @typedoc """
    The task running the turn, the run it is under, whether it is
    stopping, and what it comes back as.
    """
    @type t() :: %__MODULE__{
            task: Task.t(),
            run: Wardrik.Run.t(),
            started_at: integer(),
            stopping: Wardrik.Agent.State.Stopping.t() | nil,
            recovery: recovery()
          }
  end

  defmodule Due do
    @moduledoc """
    A turn due to run: owed again against the history the agent holds, or
    going on from the batch it last handed over, or from the park it was
    resumed from, under the trace it began on.
    """

    @enforce_keys [:recovery]
    defstruct [:recovery, :source, :sender]

    @typedoc """
    What the turn goes on from, as `t:Wardrik.Agent.State.Running.recovery/0`,
    where its events go, and who asked for it.
    """
    @type t() :: %__MODULE__{
            recovery: Wardrik.Agent.State.Running.recovery(),
            source: Source.t() | nil,
            sender: Wardrik.Principal.t() | nil
          }
  end

  defmodule Waiting do
    @moduledoc "A turn held part way through, waiting on a person."

    @enforce_keys [:turn, :source, :started_at]
    defstruct [:turn, :source, :sender, :started_at]

    @typedoc "The parked turn, where its events go, who asked for it, and when it began."
    @type t() :: %__MODULE__{
            turn: Turn.t(),
            source: Source.t(),
            sender: Wardrik.Principal.t() | nil,
            started_at: integer()
          }
  end

  # Long enough for a streaming response to notice, short enough that a kill
  # switch feels like one. A tool mid-flight will not answer inside it.
  @default_grace 2_000

  # How many message ids an agent remembers, so one sent again is taken once.
  @recent 256

  @default_idle_timeout :timer.minutes(15)

  @enforce_keys [:agent_id, :config, :history, :run_opts, :log, :host]
  defstruct [
    :generation,
    :agent_id,
    :log,
    :host,
    :config,
    :history,
    :run_opts,
    :activity,
    grace: @default_grace,
    idle_timeout: @default_idle_timeout,
    active_at: nil,
    idle_timer: nil,
    wake_only: false,
    mode: :idle,
    pending: [],
    recent: [],
    outcome: nil,
    labels: [],
    answering: []
  ]

  @doc "How long an interrupted turn is given to answer before it is killed."
  @spec default_grace() :: pos_integer()
  def default_grace, do: @default_grace

  @doc "How long an agent with nothing to do stays running, unless it is given another."
  @spec default_idle_timeout() :: timeout()
  def default_idle_timeout, do: @default_idle_timeout

  @typedoc """
  What the agent is doing. Each shape carries its own data and nothing else's.

  `Due` is an agent loaded from a dump taken mid-turn: nothing is running,
  and the turn it was running is due.
  """
  @type mode() :: :idle | Due.t() | Running.t() | Waiting.t()

  @type t() :: %__MODULE__{
          generation: String.t(),
          agent_id: Event.Bus.agent_id(),
          log: Writer.t(),
          host: Wardrik.Host.t(),
          config: Wardrik.Runtime.Settings.t(),
          history: Conversation.t(),
          run_opts: keyword(),
          activity: Activity.t(),
          grace: pos_integer(),
          idle_timeout: timeout(),
          active_at: integer() | nil,
          idle_timer: {reference(), reference()} | nil,
          wake_only: boolean(),
          mode: mode(),
          pending: [Message.t()],
          recent: [String.t()],
          outcome: outcome(),
          labels: [Wardrik.Label.t()],
          answering: [ask()]
        }

  @typedoc "A message the turn answers to another agent: the agent, and the message's id."
  @type ask() :: {Wardrik.AgentAddress.t(), String.t()}

  @typedoc "How the last turn ended, or `nil` before the first."
  @type outcome() :: nil | :ok | :failed | :interrupted

  @typedoc """
  Something the process should do on this state's behalf.

    * `{:emit, source, payload}` - publish an event
    * `{:ask_to_stop, pid}` - let a running turn finish its round, then return
    * `{:stop_now, pid}` - stop a running turn as soon as it can, mid-response
    * `{:arm_kill, task_ref, ms, dropped}` - arm a kill of the turn whose task
      `task_ref` names after `ms`, then record it with `arm/3`
    * `{:cancel_kill, timer}` - a turn answered before its kill was needed
    * `{:shutdown, task}` - the kill fired; end the task now
    * `{:close_turn, run}` - a turn has ended for good: its ledger claims
      will never be read again, and the log can drop what has aged out
    * `{:send, id, message}` - send the agent `id` a message: what a turn
      answered to an agent that asked it
  """
  @type effect() ::
          {:emit, Source.t(), Wardrik.Event.payload()}
          | {:ask_to_stop, pid()}
          | {:stop_now, pid()}
          | {:arm_kill, reference(), pos_integer(), non_neg_integer()}
          | {:cancel_kill, reference()}
          | {:shutdown, Task.t()}
          | {:close_turn, Run.t()}
          | {:send, Wardrik.AgentAddress.t(), Message.t()}

  @typedoc "What an interrupt stopped."
  @type stats() :: %{
          dropped: non_neg_integer(),
          kept: non_neg_integer(),
          resolution: :stopped | :killed | :idle | :abandoned,
          elapsed_ms: non_neg_integer()
        }

  @doc """
  Builds the state an agent starts in. See `Wardrik.Agent.initial_state/2` for
  the options.

  `agent_id` names the agent, and who the work is for.
  """
  @spec new(keyword(), Event.Bus.agent_id()) :: t()
  def new(opts, agent_id) do
    %__MODULE__{
      generation: generation(),
      agent_id: agent_id,
      log: Writer.new(agent_id),
      host: Wardrik.Host.new(),
      config: Keyword.get(opts, :config, Config.new()),
      history: Keyword.get(opts, :history, Conversation.new()),
      run_opts: Keyword.take(opts, Run.seams()),
      activity: %Activity{doing: :idle, since: System.system_time(:microsecond)},
      grace: Keyword.get(opts, :grace, @default_grace),
      idle_timeout: idle_timeout!(Keyword.get(opts, :idle_timeout, @default_idle_timeout)),
      wake_only: Keyword.get(opts, :wake_only, false)
    }
  end

  @doc """
  The same agent on `host`, which the fleet hands it each time it starts;
  see `Wardrik.Agent`. It is never written down.
  """
  @spec hosted(t(), Wardrik.Host.t()) :: t()
  def hosted(%__MODULE__{} = state, host), do: %{state | host: host}

  @doc """
  The same agent with the config and seams in `opts`, for the turns it starts
  from now on. A turn already running keeps the run it began under, and a
  parked one is resumed under the new seams.

  `:config` and `:idle_timeout` replace the agent's when given. The seams in
  `opts`, of `Wardrik.Run.seams/0`, replace every seam the agent had, so one
  left out is one the agent no longer has. Who the work is for stays with the
  agent's ID.
  """
  @spec configure(t(), keyword()) :: t()
  def configure(%__MODULE__{} = state, opts) do
    %{
      state
      | config: Keyword.get(opts, :config, state.config),
        idle_timeout: idle_timeout!(Keyword.get(opts, :idle_timeout, state.idle_timeout)),
        run_opts: Keyword.take(opts, Run.seams())
    }
  end

  defp idle_timeout!(:infinity), do: :infinity
  defp idle_timeout!(ms) when is_integer(ms) and ms > 0, do: ms

  defp idle_timeout!(other) do
    raise ArgumentError,
          ":idle_timeout must be a number of milliseconds above zero or :infinity, " <>
            "got: #{inspect(other)}"
  end

  @doc "The same agent, last busy at `now`, in milliseconds of monotonic time."
  @spec touched(t(), integer()) :: t()
  def touched(%__MODULE__{} = state, now), do: %{state | active_at: now}

  @doc """
  Whether the agent may stop for having had nothing to do since `now -
  idle_timeout`: `{:wait, ms}` until it might, `:sleep` once it may, or
  `:never`.

  An agent sleeps only with no turn running or due and nothing queued. A
  parked turn does not keep it awake: it is written down, and a decision wakes
  the agent.
  """
  @spec idle(t(), integer()) :: {:wait, pos_integer()} | :sleep | :never
  def idle(%__MODULE__{idle_timeout: :infinity}, _now), do: :never

  def idle(%__MODULE__{idle_timeout: timeout, active_at: active_at} = state, now) do
    left = active_at + timeout - now

    cond do
      left > 0 -> {:wait, left}
      at_rest?(state) -> :sleep
      true -> {:wait, timeout}
    end
  end

  defp at_rest?(%__MODULE__{mode: :idle, pending: []}), do: true
  defp at_rest?(%__MODULE__{mode: %Waiting{}, pending: []}), do: true
  defp at_rest?(%__MODULE__{}), do: false

  defp generation, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @doc """
  Whether the turn this agent waits on parked under hooks other than the ones
  it has now, by `Wardrik.Hook.revision/1`.
  """
  @spec stale?(t()) :: boolean()
  def stale?(%__MODULE__{mode: %Waiting{turn: turn}} = state),
    do: Turn.stale?(turn, Keyword.get(state.run_opts, :hooks) || [])

  def stale?(%__MODULE__{}), do: false

  @doc """
  The run a turn for this agent runs under, asked for by `sender`, carrying
  what its history holds.
  """
  @spec turn_run(t(), Wardrik.Principal.t() | nil) :: Run.t()
  def turn_run(%__MODULE__{} = state, sender) do
    opts = [name: "turn", sender: sender, host: state.host] ++ state.run_opts
    %{Run.root(state.config, state.agent_id, opts) | labels: state.labels}
  end

  @doc """
  Folds one of the agent's own events into what it is doing, and announces
  what it is doing now, on the event's span, where that changed. See
  `Wardrik.Agent.Activity`.
  """
  @spec heard(t(), Event.t()) :: {t(), [effect()]}
  def heard(%__MODULE__{activity: activity} = state, %Event{} = event) do
    case Activity.fold(activity, event) do
      ^activity ->
        {state, []}

      changed ->
        {%{state | activity: changed},
         [{:emit, event.source, %Event.ActivityChanged{activity: changed}}]}
    end
  end

  @doc "Records how far this agent's log has got."
  @spec logged(t(), Writer.t()) :: t()
  def logged(%__MODULE__{} = state, %Writer{} = log), do: %{state | log: log}

  @doc "The calls a waiting agent needs answered, or `[]` when it is not waiting."
  @spec waiting_on(t()) :: [{Wardrik.Tool.call(), String.t()}]
  def waiting_on(%__MODULE__{mode: %Waiting{turn: turn}}), do: Turn.waiting(turn)
  def waiting_on(%__MODULE__{}), do: []

  @doc "The ids of the calls a waiting agent parked to resolve `ref` for `owner`, or `[]`."
  @spec awaiting(t(), Wardrik.Credential.ref(), Wardrik.Credential.owner()) :: [String.t()]
  def awaiting(%__MODULE__{mode: %Waiting{turn: turn}}, ref, owner),
    do: Turn.awaiting(turn, ref, owner)

  def awaiting(%__MODULE__{}, _ref, _owner), do: []

  @doc "The credentials a waiting agent's calls were parked to resolve, or `[]`."
  @spec awaited(t()) :: [Wardrik.Call.Ask.credential()]
  def awaited(%__MODULE__{mode: %Waiting{turn: turn}}), do: Turn.awaited(turn)
  def awaited(%__MODULE__{}), do: []

  @doc """
  Queues a message, announces it, and says who to nudge.

  A message arriving mid-turn from the turn's sender joins that turn rather
  than waiting for it, so the running turn is asked to stop at its next
  boundary and the queue it leaves behind starts the next one. One from
  anybody else waits for the turn to end. A message whose id was among the
  last #{@recent} queued is the same message sent again, and changes nothing.
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
       [
         {:emit, Source.root(state.agent_id), %Event.MessageQueued{message: message}}
         | nudge(state.mode, message)
       ]}
    end
  end

  defp nudge(%Running{task: %Task{pid: pid}, run: run}, message) do
    if from?(message, run.sender), do: [{:ask_to_stop, pid}], else: []
  end

  defp nudge(_mode, _message), do: []

  # Messages nobody sent, as a trigger's, are answered together.
  defp from?(%Message{sender: nil}, nil), do: true
  defp from?(%Message{sender: sender}, other), do: Principal.same?(sender, other)

  @doc """
  The messages a new turn should answer, the run it is under, and the
  state with them taken: the oldest queued message, and those after it from
  the same sender, whom the run names.

  `:none` when a turn is already in flight, when one is waiting on a person, or
  when nothing is queued. A waiting turn is still the current turn: anything
  behind it waits to be answered or abandoned rather than starting beside it.

  An agent owed a turn runs one for the sender it was running it for, with
  only their queued messages ahead, against the history that already holds
  the question it was answering. One due to replay a turn
  answers `{:replay, run, checkpoint, state}`: the turn goes on from its
  checkpoint, under the trace it began on. One due to resume a parked turn
  answers `{:resume, run, turn, decisions, state}`: the turn goes on with
  the decisions it was given, under the trace that parked.
  """
  @spec take(t()) ::
          {:run, Run.t(), [Message.t()], t()}
          | {:replay, Run.t(), Turn.t(), t()}
          | {:resume, Run.t(), Turn.t(), Turn.decisions(), t()}
          | :none
  def take(%__MODULE__{mode: %Due{recovery: {:replaying, checkpoint}} = due} = state),
    do: {:replay, %{turn_run(state, due.sender) | source: due.source}, checkpoint, state}

  def take(%__MODULE__{mode: %Due{recovery: {:resuming, turn, decisions}} = due} = state),
    do: {:resume, %{turn_run(state, due.sender) | source: due.source}, turn, decisions, state}

  def take(%__MODULE__{mode: %Due{recovery: :owed, sender: sender}} = state),
    do: taken(state, sender)

  def take(%__MODULE__{mode: :idle, pending: []}), do: :none
  def take(%__MODULE__{mode: :idle} = state), do: taken(state, List.last(state.pending).sender)
  def take(%__MODULE__{}), do: :none

  defp taken(state, sender) do
    {asked, later} = state.pending |> Enum.reverse() |> Enum.split_while(&from?(&1, sender))

    {:run, turn_run(state, sender), asked,
     %{
       state
       | pending: Enum.reverse(later),
         mode: :idle,
         answering: state.answering ++ asks(asked)
     }}
  end

  defp asks(messages),
    do: for(%Message{id: id, reply_to: to} <- messages, agent <- to, do: {agent, id})

  @doc "Records the turn a `take/1` led to, and the history it was given."
  @spec started(t(), Task.t(), Run.t(), Conversation.t(), integer()) :: t()
  def started(%__MODULE__{} = state, task, %Run{} = run, %Conversation{} = history, started_at) do
    %{
      state
      | history: history,
        labels: Wardrik.Label.union(state.labels, run.labels),
        mode: %Running{task: task, run: run, started_at: started_at, recovery: :owed}
    }
  end

  @doc "Records the turn a `{:replay, ...}` from `take/1` led to."
  @spec replayed(t(), Task.t(), Run.t(), Turn.t(), integer()) :: t()
  def replayed(%__MODULE__{} = state, task, %Run{} = run, checkpoint, started_at) do
    %{
      state
      | mode: %Running{
          task: task,
          run: run,
          started_at: started_at,
          recovery: {:replaying, checkpoint}
        }
    }
  end

  @doc """
  Records the batch of tool calls the running turn is about to run, so a turn
  lost from here goes on from it, past any park it was resumed from.
  `:stale` when `pid` is not the running turn.
  """
  @spec checkpointed(t(), pid(), Turn.t()) :: {:ok, t()} | :stale
  def checkpointed(
        %__MODULE__{mode: %Running{task: %Task{pid: pid}} = running} = state,
        pid,
        checkpoint
      ),
      do: {:ok, %{state | mode: %{running | recovery: {:replaying, checkpoint}}}}

  def checkpointed(%__MODULE__{}, _pid, _checkpoint), do: :stale

  @doc """
  Records the history the running turn's `Wardrik.History` kept, with the
  messages the turn answers after it, as the agent's from now on. `:stale`
  when `pid` is not the running turn.
  """
  @spec kept(t(), pid(), Conversation.t()) :: {:ok, t()} | :stale
  def kept(
        %__MODULE__{mode: %Running{task: %Task{pid: pid}}} = state,
        pid,
        %Conversation{} = history
      ),
      do: {:ok, %{state | history: history}}

  def kept(%__MODULE__{}, _pid, _history), do: :stale

  @doc """
  Whether `task_ref` is the turn this agent is running.

  A result or a `:DOWN` from anything else belongs to a turn that was already
  settled or killed, and is not this state's business.
  """
  @spec running?(t(), reference()) :: boolean()
  def running?(%__MODULE__{mode: %Running{task: %Task{ref: ref}}}, task_ref), do: ref == task_ref
  def running?(%__MODULE__{}, _task_ref), do: false

  @doc """
  Settles a turn that answered, appending what it produced, and the `labels`
  of what it read.

  A turn that answered while stopping reports what the interrupt kept rather
  than a plain finish, so a kill switch is never silent about what it caught.
  """
  @spec settled(t(), [Conversation.message()], [Wardrik.Label.t()]) :: {t(), [effect()]}
  def settled(%__MODULE__{mode: %Running{} = running} = state, messages, labels) do
    outcome = if running.stopping, do: :interrupted, else: :ok

    state = %{
      state
      | history: Conversation.append(state.history, messages),
        outcome: outcome,
        labels: Wardrik.Label.union(state.labels, labels)
    }

    {idle(state),
     [{:emit, running.run.source, finish(running, messages)}, close(running.run)] ++
       disarm(running) ++ reply(running, state, messages, labels)}
  end

  defp finish(%Running{stopping: nil}, messages), do: %Event.TurnFinished{messages: messages}

  defp finish(%Running{stopping: stopping} = running, messages),
    do: %Event.TurnInterrupted{
      stats: stats(running.started_at, stopping.dropped, length(messages), :stopped)
    }

  defp reply(%Running{stopping: nil}, state, messages, labels),
    do: answer(state, state.answering, answered(Conversation.answer(messages)), labels)

  defp reply(%Running{stopping: %Stopping{}}, state, _messages, _labels),
    do: answer(state, state.answering, &stopped/1, [])

  @doc """
  Empties the history, and with it the labels of what it held, keeping
  everything else. `{:error, :busy}` unless the agent is idle: a turn running,
  due, or waiting on a person holds the history it began with.
  """
  @spec clear(t()) :: {:ok, t(), [effect()]} | {:error, :busy}
  def clear(%__MODULE__{mode: :idle} = state) do
    dropped = length(state.history.messages)

    {:ok, %{state | history: Conversation.new(), labels: []},
     [{:emit, Source.root(state.agent_id), %Event.ContextCleared{dropped: dropped}}]}
  end

  def clear(%__MODULE__{}), do: {:error, :busy}

  @doc "Holds a turn that stopped to ask, and announces that it can be resumed."
  @spec parked(t(), Turn.t()) :: {t(), [effect()]}
  def parked(%__MODULE__{mode: %Running{} = running} = state, turn) do
    waiting = %Waiting{
      turn: turn,
      source: running.run.source,
      sender: running.run.sender,
      started_at: running.started_at
    }

    announcement = {:emit, running.run.source, %Event.TurnParked{calls: Turn.waiting(turn)}}

    {%{state | mode: waiting}, [announcement | disarm(running)]}
  end

  @doc "Settles a turn that failed or crashed."
  @spec failed(t(), term()) :: {t(), [effect()]}
  def failed(%__MODULE__{mode: %Running{} = running} = state, reason) do
    {idle(%{state | outcome: :failed}),
     [{:emit, running.run.source, %Event.TurnFailed{reason: reason}}, close(running.run)] ++
       disarm(running) ++ answer(state, state.answering, &failed/1, [])}
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

    {drained,
     [{:stop_now, running.task.pid}, {:arm_kill, running.task.ref, state.grace, dropped}] ++
       answer(state, asks(state.pending), &stopped/1, [])}
  end

  def interrupt(%__MODULE__{mode: %Due{source: %Source{} = source} = due} = state) do
    {drained, dropped} = drain(state)

    {idle(%{drained | outcome: :interrupted}),
     [
       {:emit, source, %Event.TurnInterrupted{stats: stats(nil, dropped, 0, :abandoned)}},
       close(%{turn_run(state, due.sender) | source: source})
       | unanswered(state)
     ]}
  end

  def interrupt(%__MODULE__{mode: %Waiting{} = waiting} = state) do
    {drained, dropped} = drain(state)
    stats = stats(waiting.started_at, dropped, 0, :abandoned)

    {idle(%{drained | outcome: :interrupted}),
     [
       {:emit, waiting.source, %Event.TurnInterrupted{stats: stats}},
       close(%{turn_run(state, waiting.sender) | source: waiting.source})
       | unanswered(state)
     ]}
  end

  def interrupt(%__MODULE__{mode: %Due{recovery: :owed}} = state), do: dropped(state)
  def interrupt(%__MODULE__{mode: :idle} = state), do: dropped(state)

  # Nothing was running, so only the queue is stopped.
  defp dropped(state) do
    {drained, dropped} = drain(state)
    stats = stats(nil, dropped, 0, :idle)

    {idle(drained),
     [
       {:emit, Source.root(state.agent_id), %Event.TurnInterrupted{stats: stats}}
       | unanswered(state)
     ]}
  end

  defp drain(state), do: {%{state | pending: []}, length(state.pending)}

  @doc "Records the kill an `{:arm_kill, ...}` effect armed, behind the running turn."
  @spec arm(t(), reference(), non_neg_integer()) :: t()
  def arm(%__MODULE__{mode: %Running{} = running} = state, timer, dropped),
    do: %{state | mode: %{running | stopping: %Stopping{timer: timer, dropped: dropped}}}

  @doc """
  Fires the kill armed for the turn whose task `task_ref` names, while it is
  the turn running and stopping.

  `:stale` covers every timer that outlived what armed it: the turn answered,
  was abandoned, or was not the one running.
  """
  @spec kill(t(), reference()) :: {:kill, t(), [effect()]} | :stale
  def kill(
        %__MODULE__{mode: %Running{task: %Task{ref: ref}, stopping: %Stopping{}} = running} =
          state,
        ref
      ) do
    stats = stats(running.started_at, running.stopping.dropped, 0, :killed)

    {:kill, idle(%{state | outcome: :interrupted}),
     [
       {:shutdown, running.task},
       {:emit, running.run.source, %Event.TurnInterrupted{stats: stats}},
       close(running.run)
       | answer(state, state.answering, &stopped/1, [])
     ]}
  end

  def kill(%__MODULE__{}, _tag), do: :stale

  @doc """
  The turn a waiting agent should carry on with, and the run it carries on under:
  this node's tools, a fresh budget, and the source that parked.

  `:none` when nothing is waiting.
  """
  @spec resume(t()) :: {:resume, Run.t(), Turn.t(), integer()} | :none
  def resume(%__MODULE__{mode: %Waiting{} = waiting} = state) do
    run = %{turn_run(state, waiting.sender) | source: waiting.source}

    {:resume, run, waiting.turn, waiting.started_at}
  end

  def resume(%__MODULE__{}), do: :none

  @doc """
  Whether `token` may decide the calls this agent waits on: where it allows
  `agent.decide` on it, or its principal asked for the turn that waits and
  acts with it directly, assumed by nobody.
  """
  @spec decides?(t(), Wardrik.Token.t()) :: boolean()
  def decides?(%__MODULE__{mode: %Waiting{sender: sender}} = state, %Wardrik.Token{} = token),
    do:
      allowed?(state, token) or
        (token.assumed_by == [] and Principal.same?(token.principal, sender))

  def decides?(%__MODULE__{} = state, %Wardrik.Token{} = token), do: allowed?(state, token)

  defp allowed?(state, token),
    do: Wardrik.Token.authorize(token, "agent.decide", state.agent_id) == :ok

  @doc """
  Records the turn a `resume/1`, or a `{:resume, ...}` from `take/1`, led to:
  the park it came from and the decisions it was resumed with.
  """
  @spec resumed(t(), Task.t(), Run.t(), Turn.t(), Turn.decisions(), integer()) :: t()
  def resumed(%__MODULE__{} = state, task, %Run{} = run, turn, decisions, started_at) do
    running = %Running{
      task: task,
      run: run,
      started_at: started_at,
      recovery: {:resuming, turn, decisions}
    }

    %{state | mode: running}
  end

  defp idle(state), do: %{state | mode: :idle, answering: []}

  # What the turn owed, and what was queued, which nothing will answer now.
  defp unanswered(state),
    do: answer(state, state.answering ++ asks(state.pending), &stopped/1, [])

  defp answer(state, asks, text, labels) do
    sender = Principal.new(to_string(Wardrik.AgentAddress.resource(state.agent_id)))

    for {agent, id} <- asks,
        do:
          {:send, agent, Message.new(text.(id), "answer:" <> id, sender: sender, labels: labels)}
  end

  defp answered(""), do: &"Finished the turn that took your message #{&1} without an answer."
  defp answered(text), do: &"In answer to your message #{&1}:\n\n#{text}"

  defp failed(id), do: "Could not answer your message #{id}: the turn that took it failed."
  defp stopped(id), do: "Stopped before answering your message #{id}."

  defp close(%Run{} = run), do: {:close_turn, run}

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
