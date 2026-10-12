defmodule Wardrik.Operations.SpawnOn do
  @moduledoc """
  Starts an agent on a node of the deployment, as `Wardrik.Operations.Spawn`
  starts one anywhere. Where an agent runs is the deployment's to say, so
  only a caller whose grant reaches every agent may choose; see
  `Wardrik.Deployment`. An agent running already stays where it is.
  """

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Deployment
  alias Wardrik.Operations.Spawning

  @enforce_keys [:agent, :node]
  defstruct [:agent, :node]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), node: node()}

  @impl Wardrik.DeploymentOperation
  def subject(_request), do: Deployment.new()

  @impl Wardrik.DeploymentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id, node: node} = request, _caller) do
    with :ok <- Deployment.node(node),
         {:ok, effect} <- Spawning.of(id, node),
         do: {:ok, Change.new(request, effect)}
  end

  @impl Wardrik.Command
  def make(%Change{effect: %Spawning{} = effect}, _caller) do
    with {:ok, made} <- Spawning.make(effect), do: {:ok, Spawning.answer(made), made}
  end
end
