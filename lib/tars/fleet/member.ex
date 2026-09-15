defmodule Tars.Fleet.Member do
  @moduledoc """
  One agent as the fleet sees it: where it is, and what it is doing.

  Built from the cluster registry, so `status`, `pending` and `waiting_on` are
  whatever the agent last published through `Tars.Agent.State.meta/1`. An entry
  registered before its first publish reports `:unknown`.
  """

  @enforce_keys [:key, :pid, :node, :org, :user, :name, :status]
  defstruct [:key, :pid, :node, :org, :user, :name, :status, pending: 0, waiting_on: []]

  @typedoc "What an agent is doing, as last published."
  @type status() :: :idle | :running | :parked | :unknown

  @type t() :: %__MODULE__{
          key: String.t(),
          pid: pid(),
          node: node(),
          org: String.t(),
          user: String.t(),
          name: String.t(),
          status: status(),
          pending: non_neg_integer(),
          waiting_on: [String.t()]
        }

  @doc false
  @spec new(String.t(), pid(), map()) :: t()
  def new(key, pid, meta) when is_binary(key) and is_pid(pid) do
    {org, user, name} = Tars.Fleet.parse(key)

    %__MODULE__{
      key: key,
      pid: pid,
      node: node(pid),
      org: org,
      user: user,
      name: name,
      status: Map.get(meta, :status, :unknown),
      pending: Map.get(meta, :pending, 0),
      waiting_on: Map.get(meta, :waiting_on, [])
    }
  end
end
