defmodule Tars.Trace do
  @moduledoc """
  Where a piece of work sits in a turn's causal tree.

  A turn takes a root span. Anything it spawns takes a child span, which keeps
  the same `trace_id` and points back at its parent, so a subscriber can
  rebuild the tree from the events alone.

      trace = Tars.Trace.root(name: "turn")
      branch = Tars.Trace.child(trace, name: "web_search")

      branch.trace_id == trace.trace_id
      branch.parent_span_id == trace.span_id

  Field names and `traceparent/1` follow W3C Trace Context, so a span can be
  handed to an OpenTelemetry consumer without translation.
  """

  @enforce_keys [:trace_id, :span_id]
  defstruct [:trace_id, :span_id, :parent_span_id, :name]

  @typedoc "A span, and the trace it belongs to. `name` labels the work for a surface."
  @type t() :: %__MODULE__{
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          name: String.t() | nil
        }

  @doc """
  A span at the root of a new trace.

  Options: `:name`.
  """
  @spec root(keyword()) :: t()
  def root(opts \\ []) do
    %__MODULE__{trace_id: generate(16), span_id: generate(8), name: opts[:name]}
  end

  @doc """
  A span for work that `parent` spawned.

  Options: `:name`.
  """
  @spec child(t(), keyword()) :: t()
  def child(%__MODULE__{} = parent, opts \\ []) do
    %__MODULE__{
      trace_id: parent.trace_id,
      span_id: generate(8),
      parent_span_id: parent.span_id,
      name: opts[:name]
    }
  end

  @doc "Whether this span is the root of its trace."
  @spec root?(t()) :: boolean()
  def root?(%__MODULE__{parent_span_id: nil}), do: true
  def root?(%__MODULE__{}), do: false

  @doc "The span as a W3C `traceparent` header value."
  @spec traceparent(t()) :: String.t()
  def traceparent(%__MODULE__{} = trace) do
    "00-#{trace.trace_id}-#{trace.span_id}-01"
  end

  defp generate(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
