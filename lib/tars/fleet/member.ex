defmodule Tars.Fleet.Member do
  @moduledoc """
  One agent as the fleet sees it: where it is, and what it is doing.

  Built from the cluster registry, so `status`, `pending`, `waiting_on`,
  `delegations` and `outcome` are what the agent last published through
  `Tars.Agent.State.meta/1`.
  """

  @enforce_keys [:key, :pid, :node, :org, :user, :name, :status, :pending, :waiting_on]
  defstruct [
    :key,
    :pid,
    :node,
    :org,
    :user,
    :name,
    :status,
    :pending,
    :waiting_on,
    delegations: %{active: 0, total: 0},
    outcome: nil
  ]

  @typedoc "What an agent is doing, as last published."
  @type status() :: :idle | :running | :parked

  @type t() :: %__MODULE__{
          key: String.t(),
          pid: pid(),
          node: node(),
          org: String.t() | nil,
          user: String.t() | nil,
          name: String.t(),
          status: status(),
          pending: non_neg_integer(),
          waiting_on: [String.t()],
          delegations: %{active: non_neg_integer(), total: non_neg_integer()},
          outcome: Tars.Agent.State.outcome()
        }

  @doc false
  @spec new(String.t(), pid(), Tars.Agent.State.meta()) :: t()
  def new(key, pid, %{status: status, pending: pending, waiting_on: waiting_on} = meta) do
    {org, user, name} = Tars.Fleet.parse(key)

    %__MODULE__{
      key: key,
      pid: pid,
      node: node(pid),
      org: org,
      user: user,
      name: name,
      status: status,
      pending: pending,
      waiting_on: waiting_on,
      delegations: Map.get(meta, :delegations, %{active: 0, total: 0}),
      outcome: Map.get(meta, :outcome)
    }
  end
end
