defmodule Wardrik.Sandbox.Limits do
  @moduledoc """
  What one evaluation may take from the node.

      Wardrik.Sandbox.Limits.new(timeout_ms: :timer.seconds(5), max_steps: 1_000_000)

  | Field | Default | Bounds |
  | --- | --- | --- |
  | `:timeout_ms` | 30s | how long the evaluation may run |
  | `:max_heap_bytes` | 64 MB | memory the evaluating process may hold |
  | `:max_steps` | 10M | operations the code may execute |
  | `:max_depth` | 200 | nested calls the code may make |

  Every field takes `:infinity`, which lifts that one limit.
  """

  defstruct timeout_ms: :timer.seconds(30),
            max_heap_bytes: 64 * 1024 * 1024,
            max_steps: 10_000_000,
            max_depth: 200

  @typedoc "A bound, or `:infinity` for none."
  @type limit() :: pos_integer() | :infinity

  @typedoc "The four bounds an evaluation runs under."
  @type t() :: %__MODULE__{
          timeout_ms: limit(),
          max_heap_bytes: limit(),
          max_steps: limit(),
          max_depth: limit()
        }

  @doc """
  Builds limits from the defaults above.

  Raises on a field this struct does not have, and on a bound that is neither
  a positive integer nor `:infinity`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    limits = struct!(__MODULE__, opts)
    Enum.each(Map.from_struct(limits), &validate!/1)
    limits
  end

  defp validate!({_field, :infinity}), do: :ok
  defp validate!({_field, bound}) when is_integer(bound) and bound > 0, do: :ok

  defp validate!({field, bound}) do
    raise ArgumentError,
          "#{field} takes a positive integer or :infinity, got: #{inspect(bound)}"
  end
end
