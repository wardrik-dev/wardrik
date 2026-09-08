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
    new_context = LLM.Context.append_user_message(state.context, question)
    reply_to = self()

    task = Task.Supervisor.async_nolink(Tars.TaskSupervisor, fn ->
      {:ok, streamed} = ReqLLM.stream_text(state.config.model_spec, new_context, tools: state.tools)

      ReqLLM.StreamResponse.process_stream(
        streamed,
        on_chunk: fn chunk -> send(reply_to, {:chunk, chunk}) end,
        on_meta: fn meta -> send(reply_to, {:meta, meta}) end,
        on_result: fn result -> send(reply_to, {:result, result}) end,
        on_thinking: fn thinking -> send(reply_to, {:thinking, thinking}) end,
        on_tool_call: fn tool_call -> send(reply_to, {:tool_call, tool_call}) end
      )

      send(reply_to, {:stream_finish, streamed})
    end)

    {:noreply, %{state | context: new_context, tasks: state.tasks ++ [task.ref]}}
  end

  @impl true
  def handle_info({:stream_finish, stream_response}, state) do
    dbg(stream_response)
    case ReqLLM.StreamResponse.classify(stream_response) do
      %{type: :final_answer, text: text} ->
        Logger.debug("Final answer: #{text}")
        {:noreply, state}

      %{type: :tool_calls, tool_calls: tool_calls} ->
        Logger.debug("Tool calls: #{inspect(tool_calls)}")
        new_context = ReqLLM.Context.execute_and_append_tools(state.context, tool_calls, state.tools)
        state = %{state | context: new_context}
        send(self(), {:ask_async, "Continuing after tool calls..."})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({_ref, {:ok, %ReqLLM.Response{context: context}}}, state) do
    {:noreply, %{state | context: context}}
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
