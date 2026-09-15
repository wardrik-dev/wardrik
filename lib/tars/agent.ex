defmodule Tars.Agent do
  # Long enough for a streaming response to notice, short enough that a kill
  # switch feels like one. A tool mid-flight will not answer inside it.
  @grace 2_000

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
  `#{@grace}ms` — a tool already running does not read its mailbox — kills it.
  Either way the agent settles idle and reports what it stopped as
  `{:turn_interrupted, stats}`.

  It is an ordinary function, so an operator, a supervisor or another node can
  reach it without a terminal attached.

  The agent adds four events of its own so subscribers can follow its state
  without polling: `{:turn_started, questions}`, `{:turn_finished, messages}`,
  `{:turn_failed, reason}` and `{:turn_interrupted, stats}`. All three are emitted on the turn's root span,
  so a subscriber can tell them from events the turn's own work produced. A
  client attaching mid-turn can catch up with `status/1`.
  """
  require Logger

  use GenServer

  alias ReqLLM.Context
  alias Tars.Event
  alias Tars.LLM
  alias Tars.Scope
  alias Tars.Trace

  defstruct [
    :agent_id,
    :config,
    :context,
    :runner,
    :running,
    :source,
    :started_at,
    :stopping,
    pending: :queue.new()
  ]

  @typedoc "Whether a turn is in flight, and how many messages are waiting behind it."
  @type status() :: %{state: :idle | :running, pending: non_neg_integer()}

  @typedoc "Runs one turn and returns the messages it appended."
  @type runner() ::
          (Scope.t(), Context.t() -> {:ok, [ReqLLM.Message.t()]} | {:error, any()})

  @type t() :: %__MODULE__{
          agent_id: Tars.Event.Bus.agent_id(),
          config: LLM.Config.t(),
          context: Context.t(),
          runner: runner(),
          running: Task.t() | nil,
          source: Tars.Event.Source.t() | nil,
          pending: :queue.queue(String.t())
        }

  @doc """
  Start an agent.

  Options: `:name`, `:config`, `:context`, `:runner`. The agent's event id is
  its `:name` when given, otherwise its pid. Subscribe to it with
  `Tars.Event.Bus.subscribe/1`.
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

  @typedoc "What an interrupt stopped."
  @type stats() :: %{
          dropped: non_neg_integer(),
          kept: non_neg_integer(),
          resolution: :stopped | :killed | :idle,
          elapsed_ms: non_neg_integer()
        }

  @doc """
  Stops whatever this agent is doing and discards whatever is queued.

  Non-blocking, and safe when the agent is idle.
  """
  @spec interrupt(GenServer.server()) :: :ok
  def interrupt(agent), do: GenServer.cast(agent, :interrupt)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      agent_id: Keyword.get(opts, :name) || self(),
      config: Keyword.get(opts, :config, LLM.Config.new()),
      context: Keyword.get(opts, :context, Context.new()),
      runner: Keyword.get(opts, :runner, &LLM.Turn.run/2)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_context, _from, state), do: {:reply, state.context, state}

  def handle_call(:status, _from, state) do
    status = %{
      state: if(state.running, do: :running, else: :idle),
      pending: :queue.len(state.pending)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:interrupt, %{running: %Task{} = task} = state) do
    LLM.Turn.interrupt(task.pid)
    Process.send_after(self(), {:kill, task.ref}, @grace)

    {:noreply, %{state | pending: :queue.new(), stopping: :queue.len(state.pending)}}
  end

  def handle_cast(:interrupt, state) do
    dropped = :queue.len(state.pending)
    Event.emit(Event.Source.root(state.agent_id), {:turn_interrupted, idle_stats(dropped)})

    {:noreply, %{state | pending: :queue.new()}}
  end

  def handle_cast({:ask, question}, state) do
    state = %{state | pending: :queue.in(question, state.pending)}
    yield(state.running)

    {:noreply, state, {:continue, :maybe_run}}
  end

  # Advisory: the queue stays authoritative here, so a turn that finishes
  # without reading it loses nothing.
  defp yield(%Task{pid: pid}), do: LLM.Turn.yield(pid)
  defp yield(nil), do: :ok

  @impl true
  def handle_continue(:maybe_run, %{running: %Task{}} = state), do: {:noreply, state}

  def handle_continue(:maybe_run, state) do
    case :queue.to_list(state.pending) do
      [] ->
        {:noreply, state}

      questions ->
        context =
          Enum.reduce(questions, state.context, &LLM.Context.append_user_message(&2, &1))

        %{runner: runner} = state
        scope = Scope.root(state.config, state.agent_id, name: "turn")

        Event.emit(scope.source, {:turn_started, questions})

        task =
          Task.Supervisor.async_nolink(Tars.TaskSupervisor, fn ->
            runner.(scope, context)
          end)

        {:noreply,
         %{
           state
           | context: context,
             running: task,
             source: scope.source,
             started_at: System.monotonic_time(),
             pending: :queue.new()
         }}
    end
  end

  @impl true
  def handle_info({ref, {:ok, messages}}, %{running: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    Event.emit(state.source, settled(state, messages))
    state = %{state | context: Context.append(state.context, messages)}
    {:noreply, idle(state), {:continue, :maybe_run}}
  end

  def handle_info({:kill, ref}, %{running: %Task{ref: ref} = task, stopping: dropped} = state)
      when is_integer(dropped) do
    Task.shutdown(task, :brutal_kill)
    Event.emit(state.source, {:turn_interrupted, stats(state, dropped, 0, :killed)})

    {:noreply, idle(state), {:continue, :maybe_run}}
  end

  def handle_info({:kill, _ref}, state), do: {:noreply, state}

  def handle_info({ref, {:error, reason}}, %{running: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.error("Turn failed: #{inspect(reason)}")
    Event.emit(state.source, {:turn_failed, reason})
    {:noreply, idle(state), {:continue, :maybe_run}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %Task{ref: ref}} = state) do
    Logger.error("Turn crashed: #{inspect(reason)}")
    Event.emit(state.source, {:turn_failed, reason})
    {:noreply, idle(state), {:continue, :maybe_run}}
  end

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    {:noreply, state}
  end

  defp settled(%{stopping: nil}, messages), do: {:turn_finished, messages}

  defp settled(%{stopping: dropped} = state, messages),
    do: {:turn_interrupted, stats(state, dropped, length(messages), :stopped)}

  defp stats(state, dropped, kept, resolution) do
    %{
      dropped: dropped,
      kept: kept,
      resolution: resolution,
      elapsed_ms: Trace.elapsed_ms(state.started_at)
    }
  end

  defp idle_stats(dropped) do
    %{dropped: dropped, kept: 0, resolution: :idle, elapsed_ms: 0}
  end

  defp idle(state), do: %{state | running: nil, source: nil, started_at: nil, stopping: nil}
end
