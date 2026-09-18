defmodule Tars.Ledger.Entry do
  @moduledoc """
  One tool call as a ledger holds it: what was claimed, and what it returned.

  An entry with no result was claimed and never settled. Whether its effect
  happened is unknown, which is the state a ledger exists to make visible.

  Times are wall clock. An entry outlives the node that wrote it, where a
  monotonic reading means nothing.
  """

  alias Tars.Tool

  defstruct [:call, :result, :claimed_at, :settled_at]

  @typedoc "A claimed call, and its result once it has one."
  @type t() :: %__MODULE__{
          call: Tool.call(),
          result: Tool.Result.t() | nil,
          claimed_at: integer(),
          settled_at: integer() | nil
        }

  @doc "An entry for a call about to run."
  @spec claimed(Tool.call()) :: t()
  def claimed(call) do
    %__MODULE__{call: call, claimed_at: System.system_time(:millisecond)}
  end

  @doc "The same entry, carrying what the call returned."
  @spec settled(t(), Tool.Result.t()) :: t()
  def settled(%__MODULE__{} = entry, result) do
    %{entry | result: result, settled_at: System.system_time(:millisecond)}
  end

  @doc "Whether this entry's call has returned."
  @spec settled?(t()) :: boolean()
  def settled?(%__MODULE__{settled_at: nil}), do: false
  def settled?(%__MODULE__{}), do: true
end
