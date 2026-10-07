defmodule Wardrik.Schedule.Status do
  @moduledoc """
  One schedule as `Wardrik.Schedule.list/1` reports it: its key, the agent it
  asks, when it runs next, and when it last fired and what came of it.
  """

  @enforce_keys [:key, :pid, :agent, :name, :every, :next_at]
  defstruct [:key, :pid, :agent, :name, :every, :next_at, :last_at, :last_outcome]

  @type t() :: %__MODULE__{
          key: String.t(),
          pid: pid(),
          agent: Wardrik.AgentID.t(),
          name: String.t(),
          every: Wardrik.Schedule.every(),
          next_at: DateTime.t(),
          last_at: DateTime.t() | nil,
          last_outcome: Wardrik.Schedule.outcome() | nil
        }

  @doc false
  @spec new(String.t(), pid(), map()) :: t()
  def new(key, pid, meta) do
    struct!(__MODULE__, Map.merge(meta, %{key: key, pid: pid}))
  end
end
