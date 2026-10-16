defmodule Wardrik.Operations.ReadNodes do
  @moduledoc """
  The deployment's nodes, each with how many agents run on it, and how many
  agents sleep, on none, as `Wardrik.Deployment.Nodes`.
  """

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Query

  alias Wardrik.Deployment
  alias Wardrik.Fleet

  defstruct []

  @type t() :: %__MODULE__{}

  @impl Wardrik.DeploymentOperation
  def subject(_request), do: Deployment.new()

  @impl Wardrik.DeploymentOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(_request, _caller) do
    {asleep, running} = Enum.split_with(Fleet.list(), & &1.asleep)
    counts = Enum.frequencies_by(running, & &1.node)

    nodes = for node <- Deployment.nodes(), do: {node, Map.get(counts, node, 0)}
    {:ok, %Deployment.Nodes{nodes: nodes, asleep: length(asleep)}}
  end

  @impl Wardrik.Query
  def render(nodes), do: Wardrik.Resource.nodes(nodes)
end
