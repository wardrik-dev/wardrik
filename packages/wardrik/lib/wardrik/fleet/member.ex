defmodule Wardrik.Fleet.Member do
  @moduledoc """
  One agent as the fleet sees it: which it is, where it is, and what it is
  doing.

  Built from the cluster registry, so `status`, `pending`, `waiting_on` and
  `outcome` are what the agent last published through
  `Wardrik.Agent.State.meta/1`.
  """

  @enforce_keys [:id, :pid, :node, :status, :pending, :waiting_on]
  defstruct [:id, :pid, :node, :status, :pending, :waiting_on, outcome: nil]

  @typedoc "What an agent is doing, as last published."
  @type status() :: :idle | :running | :parked

  @type t() :: %__MODULE__{
          id: Wardrik.AgentID.t(),
          pid: pid(),
          node: node(),
          status: status(),
          pending: non_neg_integer(),
          waiting_on: [String.t()],
          outcome: Wardrik.Agent.State.outcome()
        }

  @doc false
  @spec new(Wardrik.AgentID.t(), pid(), Wardrik.Agent.State.meta()) :: t()
  def new(
        %Wardrik.AgentID{} = id,
        pid,
        %{status: status, pending: pending, waiting_on: waiting_on} = meta
      ) do
    %__MODULE__{
      id: id,
      pid: pid,
      node: node(pid),
      status: status,
      pending: pending,
      waiting_on: waiting_on,
      outcome: Map.get(meta, :outcome)
    }
  end
end
