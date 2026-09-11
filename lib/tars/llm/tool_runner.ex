defmodule Tars.LLM.ToolRunner do
  @moduledoc """
  Executes model-requested tool calls, each isolated in its own supervised task.

  A tool crash, exit or hang is contained: it becomes an error tool-result
  rather than taking down the turn. Every call is answered with exactly one
  canonical tool-result message, including calls whose task died, which is
  what `ReqLLM.Context.append_tool_exchange/3` requires.

  Each call runs under its own child span, so its events are attributed to
  that call rather than to the turn as a whole. That scope is also published
  through `Tars.Scope.Context`, which is how a tool that delegates finds its
  place in the tree.

  Spans are opened by the caller and closed inside the task; a call killed at
  the timeout is closed by the caller instead.

  Tool calls are expected in the normalized shape produced by
  `ReqLLM.Response.classify/1`: `%{id: String.t(), name: String.t(), arguments: map()}`.
  """
  alias ReqLLM.Context
  alias Tars.Event
  alias Tars.Scope

  @tool_timeout :timer.seconds(60)
  @max_concurrency 8

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}

  @spec execute_many_async([tool_call()], Scope.t()) :: [ReqLLM.Message.t()]
  def execute_many_async(tool_calls, %Scope{} = scope) do
    Tars.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      Enum.map(tool_calls, &{&1, Scope.open(scope, &1.name)}),
      fn {call, span} -> in_span(call, span) end,
      ordered: true,
      max_concurrency: @max_concurrency,
      timeout: @tool_timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, message} -> message
      {:exit, {{call, span}, reason}} -> reap(call, span, reason)
    end)
  end

  @spec execute(tool_call(), Scope.t()) :: ReqLLM.Message.t()
  def execute(%{name: name} = call, %Scope{} = scope) do
    in_span(call, Scope.open(scope, name))
  end

  defp in_span(%{id: id, name: name} = call, span) do
    span
    |> Scope.closing(&invoke(call, &1))
    |> to_message(name, id)
  end

  defp invoke(%{id: id, name: name, arguments: args}, scope) do
    :ok = Scope.Context.put(scope)

    Event.emit(scope.source, {:tool_started, id, name})

    result =
      case Enum.find(scope.config.tools, &(&1.name == name)) do
        nil -> {:error, "Unknown tool: #{name}"}
        tool -> ReqLLM.Tool.execute(tool, args)
      end

    Event.emit(scope.source, {:tool_finished, id, name, result})

    result
  end

  defp to_message({:ok, output}, name, id), do: Context.tool_result_message(name, id, output)
  defp to_message({:error, reason}, name, id), do: error_result(name, id, reason)

  defp reap(%{id: id, name: name}, span, reason) do
    Scope.close(span, {:error, reason})
    error_result(name, id, "Tool crashed: #{inspect(reason)}")
  end

  defp error_result(name, id, reason) when is_binary(reason) do
    Context.tool_result_message(name, id, %{error: reason}, %{is_error: true})
  end

  defp error_result(name, id, reason), do: error_result(name, id, inspect(reason))
end
