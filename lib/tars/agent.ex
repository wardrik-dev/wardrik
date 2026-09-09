defmodule Tars.Agent do
  @moduledoc """
  Owns one agent's conversation and serializes turns against it.

  `ask/2` is non-blocking. Messages are queued in `pending` and drained one turn
  at a time: exactly one turn task runs at once, and this GenServer is the only
  writer of `context`. Order is therefore a structural property rather than
  something callers have to coordinate.

  The turn itself runs in a `Task.Supervisor.async_nolink/3` task, so a failure
  inside `ReqLLM` or a tool cannot take the agent down.

  Stream and tool events do not pass through this process at all — the turn
  publishes them via `Tars.Events`, and any number of listeners can subscribe
  with `Tars.Events.subscribe/1`. See `Tars.Console` for a terminal one.

  The agent adds two events of its own so subscribers can tell when it goes
  idle: `{:turn_finished, messages}` and `{:turn_failed, reason}`.
  """
  require Logger

  use GenServer

  alias ReqLLM.Context
  alias Tars.Events
  alias Tars.LLM

  defstruct [
    :config,
    :context,
    :runner,
    :running,
    pending: :queue.new()
  ]

  @typedoc "Runs one turn and returns the messages it appended."
  @type runner() ::
          (LLM.Config.t(), Context.t() -> {:ok, [ReqLLM.Message.t()]} | {:error, any()})

  @type t() :: %__MODULE__{
          config: LLM.Config.t(),
          context: Context.t(),
          runner: runner(),
          running: Task.t() | nil,
          pending: :queue.queue(String.t())
        }

  @doc """
  Start an agent.

  Options: `:name`, `:config`, `:context`, `:runner`. The agent's event id is
  its `:name` when given, otherwise its pid — subscribe to it with
  `Tars.Events.subscribe/1`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec ask(GenServer.server(), String.t()) :: :ok
  def ask(agent, question), do: GenServer.cast(agent, {:ask, question})

  @spec get_context(GenServer.server()) :: Context.t()
  def get_context(agent), do: GenServer.call(agent, :get_context)

  @impl true
  def init(opts) do
    agent_id = Keyword.get(opts, :name) || self()

    config =
      opts
      |> Keyword.get(:config, LLM.Config.new())
      |> Map.put(:agent_id, agent_id)

    state = %__MODULE__{
      config: config,
      context: Keyword.get(opts, :context, Context.new()),
      runner: Keyword.get(opts, :runner, &LLM.Turn.run/2)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_context, _from, state), do: {:reply, state.context, state}

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

        %{config: config, runner: runner} = state

        task =
          Task.Supervisor.async_nolink(Tars.TaskSupervisor, fn ->
            runner.(config, context)
          end)

        {:noreply, %{state | context: context, running: task, pending: :queue.new()}}
    end
  end

  @impl true
  def handle_info({ref, {:ok, messages}}, %{running: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state = %{state | context: Context.append(state.context, messages), running: nil}
    Events.emit(state.config.agent_id, {:turn_finished, messages})
    {:noreply, state, {:continue, :maybe_run}}
  end

  def handle_info({ref, {:error, reason}}, %{running: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.error("Turn failed: #{inspect(reason)}")
    Events.emit(state.config.agent_id, {:turn_failed, reason})
    {:noreply, %{state | running: nil}, {:continue, :maybe_run}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %Task{ref: ref}} = state) do
    Logger.error("Turn crashed: #{inspect(reason)}")
    Events.emit(state.config.agent_id, {:turn_failed, reason})
    {:noreply, %{state | running: nil}, {:continue, :maybe_run}}
  end

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    {:noreply, state}
  end
end
