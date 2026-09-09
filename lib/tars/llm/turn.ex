defmodule Tars.LLM.Turn do
  @moduledoc """
  Runs a single agent turn: streams a model response, executes any tool calls,
  and loops until the model produces a final answer.

  Returns the messages appended *during* this turn — a delta, not a snapshot —
  so the caller remains the single writer of context. Stream and tool progress
  go out through `Tars.Events`, which means this module needs no subscriber pid
  and does not care how many listeners there are.

  Pure orchestration: it holds no state of its own, so tests can drive `run/2`
  directly after subscribing to the config's `agent_id`.
  """
  require Logger

  alias ReqLLM.Context
  alias Tars.Events
  alias Tars.LLM

  # A model that never stops calling tools would otherwise loop against a paid
  # API forever. Generous, but bounded.
  @max_iterations 25

  @spec run(LLM.Config.t(), Context.t()) :: {:ok, [ReqLLM.Message.t()]} | {:error, any()}
  def run(%LLM.Config{} = config, %Context{} = context) do
    loop(config, context, [], @max_iterations)
  end

  # `acc` holds this turn's messages in reverse order.
  defp loop(_config, _context, acc, 0) do
    Logger.warning("Turn hit the #{@max_iterations} iteration cap, stopping")
    {:ok, Enum.reverse(acc)}
  end

  defp loop(config, context, acc, remaining) do
    with {:ok, streamed} <- ReqLLM.stream_text(config.model_spec, context, tools: config.tools),
         {:ok, response} <- process_stream(streamed, config.agent_id) do
      case handle_response(config, context, response) do
        {:done, messages} ->
          {:ok, Enum.reverse(acc, messages)}

        {:cont, context, messages} ->
          loop(config, context, Enum.reverse(messages, acc), remaining - 1)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.warning("Error streaming text: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_response(config, context, %ReqLLM.Response{} = response) do
    case ReqLLM.Response.classify(response) do
      %{type: :final_answer, text: text} ->
        Logger.debug("Final answer: #{text}")
        {:done, [assistant_message(response, text)]}

      %{type: :tool_calls, tool_calls: tool_calls, text: text} ->
        # `classify/1` reports provider-executed calls alongside ours, but
        # `append_tool_exchange/3` only expects results for application calls.
        case Enum.reject(tool_calls, &ReqLLM.ToolCall.flagged_builtin?/1) do
          [] ->
            {:done, [assistant_message(response, text)]}

          calls ->
            Logger.debug("Tool calls: #{inspect(calls)}")
            results = LLM.ToolRunner.execute_many_async(calls, config)
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

  defp process_stream(streamed, agent_id) do
    streamed
    |> ReqLLM.StreamResponse.process_stream(
      on_chunk: &Events.emit(agent_id, {:chunk, &1}),
      on_meta: &Events.emit(agent_id, {:meta, &1}),
      on_result: &Events.emit(agent_id, {:result, &1}),
      on_thinking: &Events.emit(agent_id, {:thinking, &1}),
      on_tool_call: &Events.emit(agent_id, {:tool_call, &1})
    )
  end
end
