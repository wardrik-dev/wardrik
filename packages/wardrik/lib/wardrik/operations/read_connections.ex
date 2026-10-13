defmodule Wardrik.Operations.ReadConnections do
  @moduledoc """
  The connections the host's `Wardrik.Connections` offers an owner, and
  whether they, their org or the deployment holds each; never a value.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Query

  alias Wardrik.Connections
  alias Wardrik.Host

  @enforce_keys [:owner]
  defstruct [:owner]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t()}

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{owner: owner}), do: owner

  @impl Wardrik.FleetOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{owner: owner}, caller) do
    case Host.connections(caller.host).list(Connections.owner_of(owner)) do
      :unsupported -> {:error, Connections.unsupported()}
      connections -> {:ok, Wardrik.Resource.connections(connections)}
    end
  end
end
