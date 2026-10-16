defmodule Wardrik.Operations.Move do
  @moduledoc """
  Starts an agent again on another node of the deployment, with the state it
  had; what it is doing is interrupted, which its plan names; see
  `Wardrik.Operations.Moving`. Where an agent runs is the deployment's to
  say, so only a caller whose grant reaches every agent may move one; see
  `Wardrik.Deployment`. The answer is the agent as the fleet lists it now.
  """

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Command

  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Deployment
  alias Wardrik.Fleet
  alias Wardrik.Operations.Moving
  alias Wardrik.Resource

  @enforce_keys [:agent, :node]
  defstruct [:agent, :node]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), node: node()}

  @impl Wardrik.DeploymentOperation
  def subject(_request), do: Deployment.new()

  @impl Wardrik.DeploymentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id, node: node} = request, _caller) do
    with :ok <- Deployment.node(node) do
      case Fleet.lookup(id) do
        nil -> {:error, AgentOperation.not_found(id)}
        member -> {:ok, Change.new(request, Moving.of(member, node))}
      end
    end
  end

  @impl Wardrik.Command
  def make(%Change{effect: %Moving{agent: id} = effect}, _caller) do
    with {:ok, made} <- Moving.make(effect),
         do: {:ok, Fleet.lookup(id), made}
  end

  @impl Wardrik.Command
  def render(member), do: %{"agent" => Resource.agent(member)}
end
