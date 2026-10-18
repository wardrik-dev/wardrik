defmodule Wardrik.Fleet.Member do
  @moduledoc """
  One agent as the fleet sees it: which it is, where it is, and what it is
  doing.

  An agent awake is read from the cluster registry, so `status`, `pending`,
  `waiting_on` and `outcome` are what it last published through
  `Wardrik.Agent.State.View.meta/1`. One `asleep` is read from what it wrote
  down as it stopped, and has no `pid` or `node`; it was idle or parked. One
  its definition will start, which has written nothing, is asleep and idle.
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

  @typedoc """
  What an agent is doing, as every surface shows it: one parked waits on a
  person, asleep or awake, and one idle whose last turn failed is `:failed`.
  """
  @type state() :: :parked | :asleep | :running | :failed | :idle

  @doc "What `member` is doing, as every surface shows it."
  @spec state(t()) :: state()
  def state(%__MODULE__{status: :parked}), do: :parked
  def state(%__MODULE__{asleep: true}), do: :asleep
  def state(%__MODULE__{status: :running}), do: :running
  def state(%__MODULE__{outcome: :failed}), do: :failed
  def state(%__MODULE__{}), do: :idle

  @doc """
  What `member` is doing, in the words every surface shows: `parked`,
  `parked, asleep`, `asleep`, `running`, `idle, last failed` or `idle`.
  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{} = member) do
    case {state(member), member.asleep} do
      {:parked, true} -> "parked, asleep"
      {:failed, _asleep} -> "idle, last failed"
      {state, _asleep} -> Atom.to_string(state)
    end
  end

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
  @spec asleep(Wardrik.AgentID.t()) :: t()
  def asleep(%Wardrik.AgentID{} = id),
    do: %__MODULE__{
      id: id,
      pid: nil,
      node: nil,
      asleep: true,
      status: :idle,
      pending: 0,
      waiting_on: []
    }

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
