defmodule Wardrik.Operations.ListParked do
  @moduledoc """
  Every call an agent under a prefix waits on a person for, with the agent
  it is for, as `{id, {call, prompt}}`, the agents in the order
  `Wardrik.Fleet.list/1` gives them.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Query

  alias Wardrik.Agent
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member

  @enforce_keys [:prefix]
  defstruct [:prefix]

  @type t() :: %__MODULE__{prefix: Wardrik.AgentID.Prefix.t()}

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{prefix: prefix}), do: prefix

  @impl Wardrik.FleetOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{prefix: prefix}, _caller) do
    parked =
      for %Member{status: :parked, id: id} <- Fleet.list(prefix),
          calls = Agent.parked(id),
          is_list(calls),
          waiting <- calls,
          do: {id, waiting}

    {:ok, parked}
  end

  @impl Wardrik.Query
  def render(parked), do: Wardrik.Resource.interrupts(parked)
end
