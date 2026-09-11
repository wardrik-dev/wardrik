defmodule Tars.LLM.Turn do
  @moduledoc """
  Runs a single agent turn: streams a model response, executes any tool calls,
  and loops until the model produces a final answer.

  Returns the messages appended *during* this turn, a delta rather than a
  snapshot, so the caller remains the single writer of context. Stream and tool
  progress go out through the scope's event source, which means this module
  needs no subscriber pid and does not care how many listeners there are.

  Pure orchestration: it holds no state of its own, so tests can drive `run/2`
  directly after subscribing to the scope's agent id.
  """
  require Logger

  alias ReqLLM.Context
  alias Tars.Event
  alias Tars.LLM
  alias Tars.Scope
  alias Tars.Trace

  # A model that never stops calling tools would otherwise loop against a paid
  # API forever. Generous, but bounded.
  @max_iterations 25

  @spec run(Scope.t(), Context.t()) :: {:ok, [ReqLLM.Message.t()]} | {:error, any()}
  def run(%Scope{} = scope, %Context{} = context) do
    loop(scope, context, [], @max_iterations)
  end

  # `acc` holds this turn's messages in reverse order.
  defp loop(_scope, _context, acc, 0) do
    Logger.warning("Turn hit the #{@max_iterations} iteration cap, stopping")
    {:ok, Enum.reverse(acc)}
  end

  defp loop(scope, context, acc, remaining) do
    case request(scope, context) do
      {:ok, response} ->
        case handle_response(scope, context, response) do
          {:done, messages} ->
            {:ok, Enum.reverse(acc, messages)}

          {:cont, context, messages} ->
            loop(scope, context, Enum.reverse(messages, acc), remaining - 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Error streaming text: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp request(%Scope{source: source, config: config} = scope, context) do
    started_at = System.monotonic_time()
    Event.emit(source, {:model_started, config.model_spec})

    result =
      with {:ok, streamed} <- ReqLLM.stream_text(config.model_spec, context, stream_opts(config)) do
        process_stream(streamed, scope)
      end

    Event.emit(source, {:model_finished, outcome(result), Trace.elapsed_ms(started_at)})

    result
  end

  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome(_result), do: :ok

  defp stream_opts(%LLM.Config{system: nil} = config), do: [tools: config.tools]

  defp stream_opts(%LLM.Config{} = config),
    do: [tools: config.tools, system_prompt: config.system]

  defp handle_response(scope, context, %ReqLLM.Response{} = response) do
    case ReqLLM.Response.classify(response) do
      %{type: :final_answer, text: text} ->
        {:done, [assistant_message(response, text)]}

      %{type: :tool_calls, tool_calls: tool_calls, text: text} ->
        case Enum.reject(tool_calls, &ReqLLM.ToolCall.flagged_builtin?/1) do
          [] ->
            {:done, [assistant_message(response, text)]}

          calls ->
            results = LLM.ToolRunner.execute_many_async(calls, scope)
            append_tool_exchange(context, response, results)
        end
    end
  end

  # `response.message` is the canonical assistant message; it carries thinking
  # blocks and tool calls that rebuilding from text alone would discard.
  defp assistant_message(%ReqLLM.Response{message: nil}, text), do: Context.assistant(text)
  defp assistant_message(%ReqLLM.Response{message: message}, _text), do: message

  defp append_tool_exchange(context, response, results) do
    before = length(context.messages)

    case Context.append_tool_exchange(context, response, results) do
      {:ok, context} ->
        {:cont, context, Enum.drop(context.messages, before)}

      {:error, reason} ->
        Logger.warning("Error appending tool exchange: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_stream(streamed, %Scope{source: source}) do
    streamed
    |> ReqLLM.StreamResponse.process_stream(
      on_chunk: &Event.emit(source, {:chunk, &1}),
      on_meta: &Event.emit(source, {:meta, &1}),
      on_result: &Event.emit(source, {:result, &1}),
      on_thinking: &Event.emit(source, {:thinking, &1}),
      on_tool_call: &Event.emit(source, {:tool_call, &1})
    )
  end
end
