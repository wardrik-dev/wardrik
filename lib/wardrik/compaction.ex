defmodule Wardrik.Compaction do
  @moduledoc """
  The middleware that summarises an agent's older history as a turn begins, once the history
  passes `at` of its model's context window, keeping the last `keep` of the window word for word.

  It takes `:at`, `0.6` unless set, `:keep`, `0.25` unless set, and `:window`, the window in tokens
  where the model catalog gives none, or 128,000. The summary is the agent's own model, called in a
  `compaction` step, so policy and budgets see it as any other model call. History is cut only where
  a person's message begins, and a turn resuming isn't compacted. If the summary fails, the history
  stays as it was and the turn runs anyway. Each compaction emits `[:wardrik, :conversation,
  :compacted]` with the message and token counts before and after.
  """

  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context

  @at 0.6
  @keep 0.25
  @window 128_000
  @bytes_per_token 4
  @instructions """
  Summarise the conversation so far for yourself, to carry on from in place of it. Keep what was \
  asked and decided, what you did and found, the names, numbers and paths that matter, and what is \
  left to do. Write only the summary.\
  """

  @impl WardrikCore.Middleware
  def call(%Context{step: :turn, resume: nil} = context, next, opts),
    do: next.(compacted(context, opts))

  def call(context, next, _opts), do: next.(context)

  defp compacted(context, opts) do
    window = opts[:window] || WardrikCore.context_window(context.model) || @window

    if tokens(context.messages) > Keyword.get(opts, :at, @at) * window,
      do: summarized(context, Keyword.get(opts, :keep, @keep) * window),
      else: context
  end

  defp summarized(context, keep) do
    with {[_ | _] = older, kept} <- split(context.messages, keep),
         {:ok, summarized} <- summarize(context, older) do
      replaced(context, summarized, [summary(summarized.response) | kept])
    else
      _unchanged -> context
    end
  end

  defp split(messages, keep), do: Enum.split(messages, cut(messages, keep))

  defp cut(messages, keep) do
    starts = turn_starts(messages)

    case Enum.filter(starts, fn start -> tokens(Enum.drop(messages, start)) <= keep end) do
      [first | _rest] -> first
      [] -> List.last(starts, 0)
    end
  end

  defp turn_starts(messages),
    do: for({%{role: :user}, index} <- Enum.with_index(messages), index > 0, do: index)

  defp replaced(context, summarized, messages) do
    emit(context, messages)

    %{
      context
      | messages: messages,
        private: summarized.private,
        measurements: summarized.measurements
    }
  end

  defp summarize(context, older) do
    summarizing = %{context | instructions: @instructions, messages: older, tools: []}
    Context.run(summarizing, {:step, "compaction"}, &WardrikCore.generate/1)
  end

  defp summary(response),
    do:
      ReqLLM.Context.user(
        "A summary of the conversation before this point:\n\n" <> ReqLLM.Response.text(response)
      )

  defp emit(context, messages) do
    WardrikCore.Event.emit(context, [:wardrik, :conversation, :compacted], %{}, %{
      agent_id: context.agent_id,
      span: context.span,
      messages_before: length(context.messages),
      messages_after: length(messages),
      tokens_before: tokens(context.messages),
      tokens_after: tokens(messages)
    })
  end

  defp tokens(messages), do: div(Enum.sum_by(messages, &bytes/1), @bytes_per_token)

  defp bytes(message) do
    text = for %{text: text} when is_binary(text) <- message.content, do: byte_size(text)

    calls =
      for call <- message.tool_calls || [],
          do: byte_size(call.function.arguments || "") + byte_size(call.function.name)

    Enum.sum(text) + Enum.sum(calls)
  end
end
