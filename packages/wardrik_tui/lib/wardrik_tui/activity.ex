defmodule WardrikTUI.Activity do
  @moduledoc """
  The span tree of one turn, folded from its events.

  Every event carries the span it happened on and that span's parent, so a
  subscriber can rebuild the tree without being told its shape:

      activity = Enum.reduce(events, WardrikTUI.Activity.new(), &WardrikTUI.Activity.fold(&2, &1))

      WardrikTUI.Activity.depth(activity, span_id)
      WardrikTUI.Activity.running(activity)

  A span opens on `{:span_started, name}` and closes on `{:span_finished,
  outcome, ms}`; a turn opens and closes on its own events. Anything else
  updates what the span is currently doing. A span first seen mid-flight is
  opened where it was seen, so a client attaching late still draws a tree.

  Closing is first-wins, because a branch reaped by its parent may also have
  closed itself.

  Pure: the clock is passed in, so a surface renders the same thing in a test
  as it does at three in the morning.
  """

  alias Wardrik.Event

  @typedoc "Whether a span is still going, and how it went if not."
  @type status() :: :running | :ok | :error | :parked

  @typedoc "One span, and what it is doing."
  @type span() :: %{
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          name: String.t() | nil,
          status: status(),
          doing: String.t() | nil,
          error: term(),
          started_at: integer(),
          duration_ms: non_neg_integer() | nil
        }

  @type t() :: %__MODULE__{spans: %{String.t() => span()}, order: [String.t()]}

  defstruct spans: %{}, order: []

  @doc "An empty tree. One per turn."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Applies one event.

  Options: `:now`, the current time in milliseconds.
  """
  @spec fold(t(), Event.t(), keyword()) :: t()
  def fold(%__MODULE__{} = activity, %Event{source: source, payload: payload}, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)

    activity
    |> open(source.trace, now)
    |> absorb(source.trace.span_id, payload, now)
  end

  @doc "Every span, in the order it was first seen."
  @spec spans(t()) :: [span()]
  def spans(%__MODULE__{spans: spans, order: order}), do: Enum.map(order, &Map.fetch!(spans, &1))

  @doc "One span, or `nil` if it has not been seen."
  @spec fetch(t(), String.t()) :: span() | nil
  def fetch(%__MODULE__{spans: spans}, span_id), do: Map.get(spans, span_id)

  @doc "Spans still going, in the order they were first seen."
  @spec running(t()) :: [span()]
  def running(activity), do: activity |> spans() |> Enum.filter(&(&1.status == :running))

  @doc """
  The deepest span still going, or `nil` when nothing is.

  What the status line names: the innermost work is the most specific answer to
  "what is it doing".
  """
  @spec innermost(t()) :: span() | nil
  def innermost(%__MODULE__{} = activity) do
    activity
    |> running()
    |> Enum.max_by(&depth(activity, &1.span_id), fn -> nil end)
  end

  @doc """
  How far `span_id` sits below the root of the tree.

  A span whose parent has not been seen counts what it can, so a client that
  attached mid-turn still indents consistently.
  """
  @spec depth(t(), String.t()) :: non_neg_integer()
  def depth(%__MODULE__{spans: spans}, span_id), do: climb(spans, span_id, 0)

  @doc "How long a span has been going, or took."
  @spec elapsed_ms(span(), integer()) :: non_neg_integer()
  def elapsed_ms(%{duration_ms: ms}, _now) when is_integer(ms), do: ms
  def elapsed_ms(%{started_at: started_at}, now), do: now - started_at

  defp climb(spans, span_id, acc) do
    case Map.fetch(spans, span_id) do
      {:ok, %{parent_span_id: nil}} -> acc
      {:ok, %{parent_span_id: parent}} -> climb(spans, parent, acc + 1)
      :error -> acc
    end
  end

  defp open(%__MODULE__{spans: spans} = activity, trace, now) do
    if Map.has_key?(spans, trace.span_id) do
      activity
    else
      span = %{
        span_id: trace.span_id,
        parent_span_id: trace.parent_span_id,
        name: trace.name,
        status: :running,
        doing: nil,
        error: nil,
        started_at: now,
        duration_ms: nil
      }

      %{
        activity
        | spans: Map.put(spans, trace.span_id, span),
          order: activity.order ++ [trace.span_id]
      }
    end
  end

  defp absorb(activity, span_id, {:span_started, name}, now) do
    update(activity, span_id, &%{&1 | name: name, started_at: now})
  end

  defp absorb(activity, span_id, {:span_finished, outcome, ms}, _now) do
    close(activity, span_id, outcome, ms)
  end

  defp absorb(activity, span_id, {:turn_started, _questions}, now) do
    update(activity, span_id, &%{&1 | name: &1.name || "turn", started_at: now})
  end

  defp absorb(activity, span_id, {:turn_finished, _messages}, now) do
    close(activity, span_id, :ok, since(activity, span_id, now))
  end

  defp absorb(activity, span_id, {:turn_failed, reason}, now) do
    close(activity, span_id, {:error, reason}, since(activity, span_id, now))
  end

  defp absorb(activity, span_id, payload, _now) do
    case doing(payload) do
      :keep -> activity
      doing -> update(activity, span_id, &%{&1 | doing: doing})
    end
  end

  defp doing({:model_started, _message_id, _model_spec, _decided_by}), do: "waiting on the model"
  defp doing({:model_finished, _message_id, _outcome, _ms, _response}), do: nil
  defp doing({:thinking, _text}), do: "thinking"
  defp doing({:result, _text}), do: "answering"
  defp doing({:tool_started, _id, name, _arguments, _key, _decided_by}), do: name
  defp doing(_payload), do: :keep

  defp close(activity, span_id, outcome, ms) do
    {status, error} = resolution(outcome)

    update(activity, span_id, fn
      %{status: :running} = span ->
        %{span | status: status, doing: nil, error: error, duration_ms: ms}

      settled ->
        settled
    end)
  end

  defp resolution(:ok), do: {:ok, nil}

  # A parked call did not fail; it is waiting on a person, and colouring it
  # like a failure would tell an operator to go looking for a bug.
  defp resolution({:error, :parked}), do: {:parked, nil}
  defp resolution({:error, reason}), do: {:error, reason}

  defp since(activity, span_id, now) do
    case fetch(activity, span_id) do
      nil -> 0
      span -> now - span.started_at
    end
  end

  defp update(%__MODULE__{spans: spans} = activity, span_id, fun) do
    %{activity | spans: Map.update!(spans, span_id, fun)}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
