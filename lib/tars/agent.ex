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
  with `Tars.Event.Bus.subscribe/1`. See `Tars.TUI` for a terminal one.

  The agent adds three events of its own so subscribers can follow its state
  without polling: `{:turn_started, questions}`, `{:turn_finished, messages}`
  and `{:turn_failed, reason}`. All three are emitted on the turn's root span,
  so a subscriber can tell them from events the turn's own work produced. A
  client attaching mid-turn can catch up with `status/1`.
  """
  require Logger

  use GenServer

  alias ReqLLM.Context
  alias Tars.Event
  alias Tars.LLM
  alias Tars.Scope

  defstruct [
    :agent_id,
    :config,
    :context,
    :runner,
    :running,
    :source,
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
  def handle_cast({:ask, question}, state) do
    {:noreply, %{state | pending: :queue.in(question, state.pending)}, {:continue, :maybe_run}}
  end

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

        task =
          Task.Supervisor.async_nolink(Tars.TaskSupervisor, fn ->
            runner.(scope, context)
          end)

        Event.emit(scope.source, {:turn_started, questions})

        {:noreply,
         %{
           state
           | context: context,
             running: task,
             source: scope.source,
             pending: :queue.new()
         }}
    end
  end

  @impl true
  def handle_info({ref, {:ok, messages}}, %{running: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    Event.emit(state.source, {:turn_finished, messages})
    state = %{state | context: Context.append(state.context, messages)}
    {:noreply, idle(state), {:continue, :maybe_run}}
  end

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

  defp idle(state), do: %{state | running: nil, source: nil}
end
