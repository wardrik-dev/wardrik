defmodule WardrikCore.ToolRunner do
  @moduledoc false
  alias WardrikCore.Context
  alias WardrikCore.Event
  alias WardrikCore.InDoubt
  alias WardrikCore.Retry
  alias WardrikCore.Tool
  alias WardrikCore.ToolCall

  @timeout :timer.minutes(3)
  @max_concurrency 8

  @type outcome :: {:ok, term()} | {:error, term()} | {:park, term()}

  @doc """
  Runs `calls` and answers each, in order. Adds what they measured to the context.
  """
  @spec run(Context.t(), [ToolCall.t()], keyword()) :: {[{ToolCall.t(), outcome()}], Context.t()}
  def run(%Context{} = context, calls, opts \\ []) do
    ran = run_each(%{context | measurements: %{}}, calls, opts)
    results = Enum.map(ran, fn {call, outcome, _measured} -> {call, outcome} end)

    measured =
      Enum.reduce(ran, context, fn {_call, _outcome, measured}, context ->
        Context.measure(context, measured)
      end)

    {results, measured}
  end

  defp run_each(context, calls, opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      supervisor
      |> stream(context, calls, opts)
      |> Enum.zip_with(calls, fn {:ok, {outcome, measured}}, call -> {call, outcome, measured} end)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp stream(supervisor, context, calls, opts) do
    resume = Keyword.get(opts, :resume, %{})

    Task.Supervisor.async_stream_nolink(
      supervisor,
      calls,
      &retried(supervisor, %{context | resume: Map.get(resume, &1.id)}, &1, opts),
      ordered: true,
      max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
      timeout: :infinity
    )
  end

  defp retried(supervisor, context, call, opts) do
    timeout = Keyword.get_lazy(opts, :timeout, fn -> timeout(context.tools, call) end)
    attempt = fn -> attempt(supervisor, context, call, timeout) end

    case Retry.run(retries(context, call), attempt,
           transient: &failed/1,
           announce: &retrying(context, call, &1)
         ) do
      {:ok, ran} -> answered(context, call, ran)
      {:spent, ran, _tries} -> answered(context, call, ran)
    end
  end

  defp retries(context, call) do
    if repeatable?(Context.tool(context, call)),
      do: context.retries,
      else: Keyword.put(context.retries, :attempts, 0)
  end

  defp repeatable?(nil), do: false

  defp repeatable?(tool), do: Tool.repeatable?(tool)

  defp attempt(supervisor, context, call, timeout) do
    task = Task.Supervisor.async_nolink(supervisor, fn -> call(context, call) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, ran} -> ran
      {:exit, :killed} -> {:stopped, :killed}
      {:exit, reason} -> {:crashed, {:exit, reason}}
      nil -> {:crashed, {:exit, :timeout}}
    end
  end

  defp failed({:crashed, reason}), do: reason
  defp failed(_ran), do: nil

  defp retrying(context, call, retry) do
    Event.emit(
      context,
      [:wardrik_core, :tool_call, :retrying],
      %{},
      Map.merge(retry, %{
        agent_id: context.agent_id,
        span: context.span,
        call: call
      })
    )
  end

  defp answered(_context, _call, {:crashed, %{__exception__: true} = error}),
    do: {{:error, error}, %{}}

  defp answered(context, call, {:crashed, {:exit, reason}}),
    do: {exited(context, call, reason), %{}}

  defp answered(context, call, {:crashed, reason}), do: {exited(context, call, reason), %{}}
  defp answered(context, call, {:stopped, reason}), do: {exited(context, call, reason), %{}}
  defp answered(_context, _call, {outcome, measured}), do: {outcome, measured}

  @doc "The tool result messages for a batch's answered calls, in order, each with its labels."
  @spec messages([{ToolCall.t(), outcome()}], [Tool.t()]) :: [ReqLLM.Message.t()]
  def messages(results, tools) do
    for {call, {tag, output}} <- results, tag in [:ok, :error] do
      call.id
      |> ReqLLM.Context.tool_result(call.name, answer(tag, output))
      |> labelled(annotated(tools, call))
    end
  end

  defp annotated(tools, call) do
    case Enum.find(tools, &(&1.name == call.name)) do
      nil -> []
      tool -> Tool.annotation(tool, :labels, [])
    end
  end

  defp labelled(message, []), do: message

  defp labelled(%ReqLLM.Message{metadata: metadata} = message, labels) do
    held = Map.get(metadata, :labels, [])
    %{message | metadata: Map.put(metadata, :labels, Enum.uniq(held ++ labels))}
  end

  defp call(context, tool_call) do
    started(context, tool_call)

    case Context.run(context, {:tool_call, tool_call}, &execute/1) do
      {:ok, %Context{response: outcome, measurements: measured}} -> {outcome, measured}
      {:error, reason} -> {{:error, reason}, %{}}
      {:park, reason, %Context{measurements: measured}} -> {{:park, reason}, measured}
    end
  catch
    :error, reason -> {:crashed, Exception.normalize(:error, reason, __STACKTRACE__)}
    kind, reason -> {:crashed, {kind, reason}}
  end

  defp started(%Context{call_started: nil}, _call), do: :ok
  defp started(%Context{call_started: started}, call), do: started.(call.id)

  defp exited(context, call, reason) do
    Event.emit(context, [:wardrik_core, :tool_call, :exit], %{
      agent_id: context.agent_id,
      call: call,
      reason: reason
    })

    {:error, {:exit, reason}}
  end

  defp execute(%Context{step: {:tool_call, call}, tools: tools} = context) do
    case InDoubt.check(context, call) do
      :run -> {:ok, answered(context, Tool.call(tools, call, context))}
      answer -> {:ok, answered(context, answer)}
    end
  end

  defp answered(_context, {tag, output, %Context{} = context}) when tag in [:ok, :error],
    do: answered(context, {tag, output})

  defp answered(context, answer), do: %{context | response: answer}

  defp timeout(tools, call) do
    case Enum.find(tools, &(&1.name == call.name)) do
      nil -> @timeout
      tool -> Tool.annotation(tool, :timeout, @timeout)
    end
  end

  defp answer(:ok, output), do: output

  defp answer(:error, %ReqLLM.ToolResult{output: reason} = result),
    do: %{result | output: %{error: message(reason)}}

  defp answer(:error, reason), do: %{error: message(reason)}

  defp message(reason) when is_binary(reason), do: reason
  defp message({:exit, :killed}), do: "The call was stopped before it finished."

  defp message({:exit, :timeout}), do: "The call ran out of time, so it was stopped."

  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(%{error: error}) when is_binary(error), do: error

  defp message(reason), do: inspect(reason)
end
