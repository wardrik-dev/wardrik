defmodule Wardrik.Delegation do
  @moduledoc """
  The delegations of one turn, folded from its `:lifecycle` events.

  A delegation is one `Wardrik.Subagent.run/3`: it is identified by its own span
  and it is known from the
  `Wardrik.Event.DelegationStarted` and `Wardrik.Event.DelegationFinished`
  events the subagent emits there. Spans are followed too, so a delegation's
  depth under other delegations and the work under it are known.

      delegations = Enum.reduce(events, Wardrik.Delegation.new(), &Wardrik.Delegation.fold(&2, &1))

      Wardrik.Delegation.summary(delegations)   #=> %{active: 2, total: 4}
      Wardrik.Delegation.list(delegations)      # every delegation, oldest first

  `Wardrik.Event.TurnStarted` starts over. A turn ending with delegations still
  running closes them as interrupted, and a span closed as an error with a
  delegation running on it closes the delegation the same way, which is how a
  branch killed by its fan-out is settled.

  Nested delegations count once each: `summary/1` counts every delegation of
  the turn at any depth, and `depth/2` says how many delegations sit above one.
  """

  alias Wardrik.Event

  @typedoc "Whether a delegation is still going, and how it went if not."
  @type status() :: :running | :ok | :error

  @typedoc "One delegation."
  @type delegation() :: %{
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          name: String.t() | nil,
          task: String.t(),
          status: status(),
          output: String.t() | nil,
          error: term(),
          started_at: integer(),
          duration_ms: non_neg_integer() | nil
        }

  @typedoc "A span seen: where it sits and how it went."
  @type span() :: %{
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          name: String.t() | nil,
          status: status(),
          started_at: integer(),
          duration_ms: non_neg_integer() | nil
        }

  @type t() :: %__MODULE__{
          records: %{String.t() => delegation()},
          spans: %{String.t() => span()},
          order: [String.t()]
        }

  defstruct records: %{}, spans: %{}, order: []

  @doc "No delegations. One per turn."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Applies one event."
  @spec fold(t(), Event.t()) :: t()
  def fold(%__MODULE__{}, %Event{payload: %Event.TurnStarted{}}), do: new()

  def fold(%__MODULE__{} = delegations, %Event{source: source, payload: payload, at: at}) do
    now = div(at, 1_000)

    delegations
    |> see(source.trace, now)
    |> absorb(source.trace.span_id, payload, now)
  end

  @doc "Every delegation, oldest first."
  @spec list(t()) :: [delegation()]
  def list(%__MODULE__{records: records, order: order}),
    do: Enum.map(order, &Map.fetch!(records, &1))

  @doc "One delegation, by the span it ran on, or `nil`."
  @spec fetch(t(), String.t()) :: delegation() | nil
  def fetch(%__MODULE__{records: records}, span_id), do: Map.get(records, span_id)

  @doc "How many delegations are still going, and how many the turn has started."
  @spec summary(t()) :: %{active: non_neg_integer(), total: non_neg_integer()}
  def summary(%__MODULE__{records: records}) do
    %{
      active: Enum.count(records, fn {_id, record} -> record.status == :running end),
      total: map_size(records)
    }
  end

  @doc "How many delegations sit above the one on `span_id`."
  @spec depth(t(), String.t()) :: non_neg_integer()
  def depth(%__MODULE__{} = delegations, span_id) do
    case Map.get(delegations.spans, span_id) do
      nil -> 0
      %{parent_span_id: nil} -> 0
      %{parent_span_id: parent} -> above(delegations, parent, 0)
    end
  end

  defp above(delegations, span_id, count) do
    count = if Map.has_key?(delegations.records, span_id), do: count + 1, else: count

    case Map.get(delegations.spans, span_id) do
      %{parent_span_id: parent} when is_binary(parent) -> above(delegations, parent, count)
      _top -> count
    end
  end

  @doc """
  The work under the delegation on `span_id`: every span below it down to the
  next delegation, oldest first.
  """
  @spec activity(t(), String.t()) :: [span()]
  def activity(%__MODULE__{} = delegations, span_id) do
    delegations.spans
    |> Map.values()
    |> Enum.reject(&Map.has_key?(delegations.records, &1.span_id))
    |> Enum.filter(&under?(delegations, &1.span_id, span_id))
    |> Enum.sort_by(& &1.started_at)
  end

  defp under?(delegations, span_id, ancestor) do
    case Map.get(delegations.spans, span_id) do
      %{parent_span_id: ^ancestor} ->
        true

      %{parent_span_id: parent} when is_binary(parent) ->
        not Map.has_key?(delegations.records, parent) and under?(delegations, parent, ancestor)

      _other ->
        false
    end
  end

  @doc "How long a delegation or span has been going, or took, at `now` in milliseconds."
  @spec elapsed_ms(delegation() | span(), integer()) :: non_neg_integer()
  def elapsed_ms(%{duration_ms: ms}, _now) when is_integer(ms), do: ms
  def elapsed_ms(%{started_at: started_at}, now), do: max(now - started_at, 0)

  # -- folding ---------------------------------------------------------------

  defp see(%__MODULE__{spans: spans} = delegations, trace, now) do
    if Map.has_key?(spans, trace.span_id) do
      delegations
    else
      span = %{
        span_id: trace.span_id,
        parent_span_id: trace.parent_span_id,
        name: trace.name,
        status: :running,
        started_at: now,
        duration_ms: nil
      }

      %{delegations | spans: Map.put(spans, trace.span_id, span)}
    end
  end

  defp absorb(delegations, span_id, %Event.SpanStarted{name: name}, now) do
    update_span(delegations, span_id, &%{&1 | name: name, started_at: now})
  end

  defp absorb(delegations, span_id, %Event.SpanFinished{outcome: outcome, duration_ms: ms}, now) do
    closed =
      delegations
      |> update_span(span_id, &close(&1, outcome, ms))
      |> update_record(span_id, &close(&1, outcome, ms))

    case outcome do
      {:error, _reason} -> close_descendants(closed, span_id, outcome, now)
      :ok -> closed
    end
  end

  defp absorb(delegations, span_id, %Event.DelegationStarted{prompt: task}, now) do
    if Map.has_key?(delegations.records, span_id) do
      delegations
    else
      span = Map.fetch!(delegations.spans, span_id)

      record = %{
        span_id: span_id,
        parent_span_id: span.parent_span_id,
        name: span.name,
        task: task,
        status: :running,
        output: nil,
        error: nil,
        started_at: now,
        duration_ms: nil
      }

      %{
        delegations
        | records: Map.put(delegations.records, span_id, record),
          order: delegations.order ++ [span_id]
      }
    end
  end

  defp absorb(
         delegations,
         span_id,
         %Event.DelegationFinished{outcome: outcome, duration_ms: ms},
         _now
       ) do
    update_record(delegations, span_id, fn
      %{status: :running} = record ->
        case outcome do
          {:ok, output} -> %{record | status: :ok, output: output, duration_ms: ms}
          {:error, reason} -> %{record | status: :error, error: reason, duration_ms: ms}
        end

      settled ->
        settled
    end)
  end

  defp absorb(delegations, _span_id, %ended{}, now)
       when ended in [Event.TurnFinished, Event.TurnFailed, Event.TurnInterrupted] do
    records =
      Map.new(delegations.records, fn
        {id, %{status: :running} = record} ->
          {id,
           %{
             record
             | status: :error,
               error: :interrupted,
               duration_ms: max(now - record.started_at, 0)
           }}

        settled ->
          settled
      end)

    %{delegations | records: records}
  end

  defp absorb(delegations, _span_id, _payload, _now), do: delegations

  defp close_descendants(delegations, ancestor, outcome, now) do
    Enum.reduce(Map.keys(delegations.spans), delegations, fn id, acc ->
      if descendant?(acc, id, ancestor) do
        acc
        |> update_span(id, &close(&1, outcome, max(now - &1.started_at, 0)))
        |> update_record(id, &close(&1, outcome, max(now - &1.started_at, 0)))
      else
        acc
      end
    end)
  end

  defp descendant?(delegations, id, ancestor) do
    case Map.get(delegations.spans, id) do
      %{parent_span_id: ^ancestor} ->
        true

      %{parent_span_id: parent} when is_binary(parent) ->
        descendant?(delegations, parent, ancestor)

      _other ->
        false
    end
  end

  defp close(%{status: :running} = item, outcome, ms) do
    case outcome do
      :ok ->
        %{item | status: :ok, duration_ms: ms}

      {:error, reason} ->
        item |> Map.put(:status, :error) |> put_error(reason) |> Map.put(:duration_ms, ms)
    end
  end

  defp close(settled, _outcome, _ms), do: settled

  defp put_error(%{error: _} = record, reason), do: %{record | error: reason}
  defp put_error(span, _reason), do: span

  defp update_span(delegations, span_id, fun) do
    case Map.get(delegations.spans, span_id) do
      nil -> delegations
      span -> %{delegations | spans: Map.put(delegations.spans, span_id, fun.(span))}
    end
  end

  defp update_record(delegations, span_id, fun) do
    case Map.get(delegations.records, span_id) do
      nil -> delegations
      record -> %{delegations | records: Map.put(delegations.records, span_id, fun.(record))}
    end
  end
end
