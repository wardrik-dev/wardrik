defmodule Wardrik.Compaction do
  @moduledoc """
  Middleware that summarises an agent's older history when a turn starts.

  It runs once the history passes `:at` of the model's context window. The most recent `:keep`
  of the window stays word for word.

  ## Options

    * `:at` - the share of the window that triggers compaction. `0.6` unless set.
    * `:keep` - the share of the window kept word for word. `0.25` unless set.
    * `:window` - the window in tokens, if the model catalog has none. `128_000` unless set.

  ## Behaviour

    * The agent's own model writes the summary, in a `compaction` step. Policy and budgets apply
      as for any model call.
    * History is only cut where a person's message starts.
    * Resumed turns aren't compacted.
    * The summary keeps the labels of what it replaces, such as `"outside"`.
    * If summarising fails, the history is left as it is and the turn runs anyway.
    * Each compaction emits `[:wardrik, :conversation, :compacted]` with message and token counts
      before and after.
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
      replaced(context, summarized, [summary(summarized.response, older) | kept])
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

  defp summary(response, older) do
    ReqLLM.Context.user(
      "A summary of the conversation before this point:\n\n" <> ReqLLM.Response.text(response),
      %{labels: Context.labels(older)}
    )
  end

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
