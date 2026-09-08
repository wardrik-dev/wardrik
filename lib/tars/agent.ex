defmodule Tars.Agent do
  @moduledoc """
  GenServer managing agent state.
  """
  require Logger

  use GenServer

  alias Tars.LLM

  defstruct [
    :config,
    :context,
    tools: [],
    tasks: []
  ]

  @type t() :: %__MODULE__{
          config: LLM.Config.t(),
          context: ReqLLM.Context.t(),
          tools: list(ReqLLM.Tool.t()),
          tasks: list(Task.t())
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    state = %{
      llm: Keyword.get(opts, :llm, LLM.new()),
      config: Keyword.get(opts, :config, LLM.Config.new()),
      context: Keyword.get(opts, :context, %ReqLLM.Context{}),
      tools: Keyword.get(opts, :tools, []),
      tasks: []
    }

    {:ok, state}
  end

  def ask_async(agent, question) do
    GenServer.cast(agent, {:ask_async, question})
  end

  @impl true
  def handle_cast({:ask_async, question}, state) do
    new_llm = LLM.Context.append_user_message(state.llm.context, question)
    subscriber = self()
    dbg(new_llm)

    task =
      Task.Supervisor.async_nolink(Tars.TaskSupervisor, fn ->
        LLM.stream(state.llm, subscriber)
      end)

    {:noreply, %{state | llm: new_llm, tasks: state.tasks ++ [task.ref]}}
  end

  @impl true
  def handle_info({:stream_finish, stream_response}, state) do
    Logger.debug("stream_finish: #{inspect(stream_response)}")
    {:noreply, %{state | context: stream_response.context}}
  end

  @impl true
  def handle_info({ref, {:stream_finish, stream_response}}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | context: stream_response.context}}
  end

  @impl true
  def handle_info({ref, {:ok, %ReqLLM.Response{context: context}}}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | context: context}}
  end

  @impl true
  def handle_info({ref, :error}, state) do
    Process.demonitor(ref, [:flush])
    Logger.error("Task #{inspect(ref)} failed with error")
    {:noreply, %{state | tasks: List.delete(state.tasks, ref)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, :normal}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | tasks: List.delete(state.tasks, ref)}}
  end

  @impl true
  def handle_info({:chunk, _chunk}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:meta, _meta}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:result, result}, state) do
    IO.write(result)
    {:noreply, state}
  end

  @impl true
  def handle_info({:thinking, thinking}, state) do
    IO.write(thinking)
    {:noreply, state}
  end
end
