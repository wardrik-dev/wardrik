defmodule Wardrik.Operations.ReadConnections do
  @moduledoc """
  The connections the host's `Wardrik.Connections` offers an owner, and
  whether they, their org or the deployment holds each; never a value.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Query

  alias Wardrik.Connections

  @enforce_keys [:owner]
  defstruct [:owner]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t()}

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{owner: owner}), do: owner

  @impl Wardrik.FleetOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{owner: owner}, _caller) do
    with {:ok, module} <- Connections.module() do
      {:ok, Wardrik.Resource.connections(module.list(Connections.owner_of(owner)))}
    end
  end
end
