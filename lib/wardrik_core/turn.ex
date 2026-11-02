defmodule WardrikCore.Turn do
  @moduledoc false
  alias WardrikCore.Context
  alias WardrikCore.Event
  alias WardrikCore.InDoubt
  alias WardrikCore.Keys
  alias WardrikCore.Resume
  alias WardrikCore.Retry
  alias WardrikCore.ToolRunner
  alias WardrikCore.Usage

  @type checkpoint :: %{
          messages: [ReqLLM.Message.t()],
          calls: [WardrikCore.ToolCall.t()],
          rounds: non_neg_integer() | :infinity,
          metadata: map(),
          private: map(),
          span: WardrikCore.Span.t(),
          measurements: map()
        }

  @spec run(Context.t()) :: WardrikCore.Middleware.result()
  def run(%Context{} = context) do
    context
    |> with_tools()
    |> Context.run(:turn, fn context -> loop(context, context.max_rounds) end)
  end

  @doc """
  Re-enters a turn where it parked.
  """
  @spec resume(Context.t(), Resume.t()) :: WardrikCore.Middleware.result()
  def resume(%Context{} = context, %Resume{} = resume) do
    context = %{with_tools(context) | resume: resume}
    Context.run(context, :turn, fn context -> reenter(context, resume) end)
  end

  @doc """
  Carries on a turn lost while its tools ran, from the checkpoint it saved. Each call may already
  have run. A call whose tool is safe to repeat, `read_only` or `idempotent`, is repeated. Any
  other parks as `:in_doubt`.
  """
  @spec recover(Context.t(), checkpoint()) :: WardrikCore.Middleware.result()
  def recover(
        %Context{} = context,
        %{messages: messages, calls: calls, rounds: rounds} = checkpoint
      ) do
    metadata = Map.merge(context.metadata, checkpoint.metadata)

    context = %{
      with_tools(context)
      | messages: messages,
        metadata: metadata,
        private: checkpoint.private,
        span: checkpoint.span,
        measurements: checkpoint.measurements
    }

    Context.run(context, :turn, fn context ->
      run_calls(context, calls, rounds, resume: InDoubt.resumes(calls))
    end)
  end

  @doc "Calls the context's model once, as a `:generate` step, streaming nothing."
  @spec call_model(Context.t()) :: WardrikCore.Middleware.result()
  def call_model(%Context{} = context),
    do: Context.run(context, :generate, &called(&1, fn _chunk -> :ok end))

  @doc "Asks the turn running in `pid` to end at its next step."
  @spec yield(pid()) :: :ok
  def yield(pid) do
    send(pid, {__MODULE__, :yield})
    :ok
  end

  defp reenter(context, %Resume{reason: {:tool_calls, results}} = resume) do
    context = clear_resume(context)
    parked = parked_calls(results)
    calls = Enum.map(parked, fn {call, _reason} -> call end)
    {rerun, context} = ToolRunner.run(context, calls, resume: resume_each(parked, resume))

    continue(context, replace_outcomes(results, rerun), context.max_rounds)
  end

  defp reenter(context, _resume), do: loop(context, context.max_rounds)

  defp parked_calls(results) do
    for {call, {:park, reason}} <- results, do: {call, reason}
  end

  defp resume_each(parked, resume) do
    Map.new(parked, fn {call, reason} -> {call.id, %{resume | reason: reason}} end)
  end

  defp replace_outcomes(results, rerun) do
    rerun_outcomes = Map.new(rerun, fn {call, outcome} -> {call.id, outcome} end)

    Enum.map(results, fn {call, outcome} ->
      {call, Map.get(rerun_outcomes, call.id, outcome)}
    end)
  end

  defp with_tools(context) do
    tools =
      Enum.flat_map(context.capabilities, fn entry ->
        {module, opts} = Context.entry(entry)
        module.tools(context, opts)
      end)

    %{context | tools: tools}
  end

  defp loop(_context, 0), do: {:error, :max_rounds}

  defp loop(context, rounds) do
    if yield_requested?(), do: {:ok, context}, else: step(context, rounds)
  end

  defp step(context, rounds) do
    with {:ok, context} <- generated(context) do
      context = clear_resume(context)

      case tool_calls(context.response) do
        [] -> {:ok, context}
        calls -> run_tools(context, calls, rounds)
      end
    end
  end

  defp generated(%Context{resume: %Resume{reason: %Retry.Exhausted{}, input: input}} = context)
       when is_map(input) do
    case Map.get(input, "model") do
      {:deny, reason} -> {:error, reason}
      _try_again -> retried(context)
    end
  end

  defp generated(context), do: retried(context)

  defp retried(context) do
    generate = fn -> Context.run(context, :generate, &generate/1) end

    case Retry.run(context.retries, generate,
           transient: &model_failure/1,
           announce: &model_retrying(context, &1)
         ) do
      {:ok, generated} -> generated
      {:spent, failed, tries} -> spent(context, failed, tries)
    end
  end

  defp model_failure({:error, reason}), do: if(Retry.transient?(reason), do: reason)
  defp model_failure(_generated), do: nil

  defp model_retrying(context, retry) do
    Event.emit(
      context,
      [:wardrik_core, :message, :retrying],
      %{},
      Map.merge(retry, %{agent_id: context.agent_id, span: context.span})
    )
  end

  defp spent(context, {:error, reason} = failed, tries) do
    case Retry.on_exhausted(context.retries) do
      :fail ->
        failed

      :ask ->
        message = "The model failed #{times(tries)}: #{reason_text(reason)}. Try again?"
        {:park, %Retry.Exhausted{message: message, labels: Context.labels(context)}, context}
    end
  end

  defp times(1), do: "once"
  defp times(tries), do: "#{tries} times"

  defp reason_text(%{__exception__: true} = error), do: Exception.message(error)
  defp reason_text(reason), do: inspect(reason)

  defp tool_calls(response) do
    response
    |> ReqLLM.Response.tool_calls()
    |> Enum.map(&WardrikCore.ToolCall.from_req_llm/1)
  end

  defp run_tools(context, calls, rounds) do
    checkpoint = %{
      messages: context.messages,
      calls: calls,
      rounds: rounds,
      metadata: context.metadata,
      private: context.private,
      span: context.span,
      measurements: context.measurements
    }

    :ok = save_checkpoint(context, checkpoint)
    run_calls(context, calls, rounds)
  end

  defp run_calls(context, calls, rounds, opts \\ []) do
    {results, context} = ToolRunner.run(context, calls, opts)
    continue(context, results, rounds)
  end

  defp save_checkpoint(%Context{checkpoint: nil}, _checkpoint), do: :ok
  defp save_checkpoint(%Context{checkpoint: save}, checkpoint), do: save.(checkpoint)

  defp continue(context, results, rounds) do
    if any_parked?(results) do
      {:park, {:tool_calls, results}, context}
    else
      context
      |> append_messages(ToolRunner.messages(results, context.tools))
      |> loop(less(rounds))
    end
  end

  defp less(:infinity), do: :infinity
  defp less(rounds), do: rounds - 1

  defp yield_requested? do
    receive do
      {__MODULE__, :yield} -> true
    after
      0 -> false
    end
  end

  defp any_parked?(results) do
    Enum.any?(results, fn {_call, outcome} -> match?({:park, _reason}, outcome) end)
  end

  defp clear_resume(context), do: %{context | resume: nil}

  defp append_messages(context, messages),
    do: %{context | messages: context.messages ++ messages}

  defp dispatch(%Context{on_chunk: handlers} = context, chunk) do
    streamed(context, chunk)
    Enum.each(handlers, fn handler -> handler.(chunk) end)
  end

  defp streamed(context, %ReqLLM.StreamChunk{type: type, text: text})
       when type in [:content, :thinking] do
    Event.emit(context, [:wardrik_core, :message, :delta], %{}, %{
      agent_id: context.agent_id,
      span: context.span,
      kind: type,
      text: text
    })
  end

  defp streamed(_context, _chunk), do: :ok

  defp prompt(%Context{instructions: nil, messages: messages}), do: messages

  defp prompt(%Context{instructions: instructions, messages: messages}),
    do: [ReqLLM.Context.system(instructions) | messages]

  defp generate(%Context{} = context), do: called(context, &dispatch(context, &1))

  defp called(context, on_chunk) do
    tools = Enum.map(context.tools, fn tool -> tool.req_llm end)

    opts = [tools: tools] ++ Keys.model_options(context, context.model)

    with {:ok, streamed} <- ReqLLM.stream_text(context.model, prompt(context), opts),
         {:ok, response} <- ReqLLM.StreamResponse.process_stream(streamed, on_chunk: on_chunk) do
      context =
        Context.measure(
          %{context | response: response},
          Usage.measurements(response, context.model, context.prices)
        )

      {:ok, append_messages(context, [response.message])}
    end
  end
end
