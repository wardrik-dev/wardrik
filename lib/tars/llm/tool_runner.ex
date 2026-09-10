defmodule Tars.LLM.ToolRunner do
  @moduledoc """
  Executes model-requested tool calls, each isolated in its own supervised task.

  A tool crash, exit or hang is contained: it becomes an error tool-result
  rather than taking down the turn. Every call is answered with exactly one
  canonical tool-result message, including calls whose task died, which is
  what `ReqLLM.Context.append_tool_exchange/3` requires.

  Each call runs under its own child scope, so its events are attributed to
  that call rather than to the turn as a whole. That scope is also published
  through `Tars.Scope.Context`, which is how a tool that delegates finds its
  place in the tree.

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
      tool_calls,
      &execute(&1, scope),
      ordered: true,
      max_concurrency: @max_concurrency,
      timeout: @tool_timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, message} -> message
      {:exit, {call, reason}} -> crashed_result(call, reason)
    end)
  end

  @spec execute(tool_call(), Scope.t()) :: ReqLLM.Message.t()
  def execute(%{id: id, name: name, arguments: args}, %Scope{} = scope) do
    scope = Scope.child(scope, name: name)
    :ok = Scope.Context.put(scope)

    Event.emit(scope.source, {:tool_started, id, name})

    result =
      case Enum.find(scope.config.tools, &(&1.name == name)) do
        nil -> {:error, "Unknown tool: #{name}"}
        tool -> ReqLLM.Tool.execute(tool, args)
      end

    Event.emit(scope.source, {:tool_finished, id, name, result})

    case result do
      {:ok, output} -> Context.tool_result_message(name, id, output)
      {:error, reason} -> error_result(name, id, reason)
    end
  end

  defp crashed_result(%{id: id, name: name}, reason) do
    error_result(name, id, "Tool crashed: #{inspect(reason)}")
  end

  defp error_result(name, id, reason) when is_binary(reason) do
    Context.tool_result_message(name, id, %{error: reason}, %{is_error: true})
  end

  defp error_result(name, id, reason), do: error_result(name, id, inspect(reason))
end
