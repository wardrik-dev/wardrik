defmodule Wardrik.Operations.ReadAgent do
  @moduledoc """
  An agent's snapshot: what it is doing, what it waits on, and its
  conversation, as `Wardrik.Resource.snapshot/2` shapes it.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Query

  alias Wardrik.Agent
  alias Wardrik.AgentOperation
  alias Wardrik.Resource

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{agent: id}, _caller) do
    case Agent.snapshot(id) do
      {:error, :not_found} -> {:error, AgentOperation.not_found(id)}
      snapshot -> {:ok, Resource.snapshot(id, snapshot)}
    end
  end
end
