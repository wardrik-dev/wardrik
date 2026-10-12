defmodule Wardrik.Operations.ReadConnections do
  @moduledoc """
  The connections the host's `Wardrik.Connections` offers an owner, and
  whether they, their org or the deployment holds each; never a value.
  """

  @behaviour Wardrik.Query

  alias Wardrik.Connections

  @enforce_keys [:owner]
  defstruct [:owner]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t()}

  @doc "The owner's agents, which a caller reaches to read their connections."
  @spec subject(t()) :: Wardrik.AgentID.Prefix.t()
  def subject(%__MODULE__{owner: owner}), do: owner

  @doc "What a grant must allow on them."
  @spec action() :: Wardrik.Grant.action()
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{owner: owner}, _caller) do
    with {:ok, module} <- Connections.module() do
      {:ok, Wardrik.Resource.connections(module.list(Connections.owner_of(owner)))}
    end
  end
end
