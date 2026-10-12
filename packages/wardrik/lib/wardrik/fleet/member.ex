defmodule Wardrik.Fleet.Member do
  @moduledoc """
  One agent as the fleet sees it: which it is, where it is, and what it is
  doing.

  An agent awake is read from the cluster registry, so `status`, `pending`,
  `waiting_on` and `outcome` are what it last published through
  `Wardrik.Agent.State.View.meta/1`. One `asleep` is read from what it wrote
  down as it stopped, and has no `pid` or `node`; it was idle or parked.
  """

  @enforce_keys [:id, :pid, :node, :status, :pending, :waiting_on]
  defstruct [:id, :pid, :node, :status, :pending, :waiting_on, outcome: nil, asleep: false]

  @typedoc "What an agent is doing, as last published."
  @type status() :: :idle | :running | :parked

  @type t() :: %__MODULE__{
          id: Wardrik.AgentID.t(),
          pid: pid() | nil,
          node: node() | nil,
          asleep: boolean(),
          status: status(),
          pending: non_neg_integer(),
          waiting_on: [String.t()],
          outcome: Wardrik.Agent.State.outcome()
        }

  @doc false
  @spec new(Wardrik.AgentID.t(), pid(), Wardrik.Agent.State.View.meta()) :: t()
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

  @doc false
  @spec asleep(Wardrik.AgentID.t(), Wardrik.Agent.State.Stored.t()) :: t()
  def asleep(%Wardrik.AgentID{} = id, dumped) do
    meta = Wardrik.Agent.State.View.meta_at_rest(dumped)

    %__MODULE__{
      id: id,
      pid: nil,
      node: nil,
      asleep: true,
      status: meta.status,
      pending: meta.pending,
      waiting_on: meta.waiting_on,
      outcome: meta.outcome
    }
  end
end
