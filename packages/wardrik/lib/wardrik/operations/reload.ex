defmodule Wardrik.Operations.Reload do
  @moduledoc """
  Has every node whose host reads its definitions again do so, as
  `Wardrik.Definition`'s `c:Wardrik.Definition.reload/0`, and brings the
  agents each runs to what they say now.
  """

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Deployment
  alias Wardrik.Error
  alias Wardrik.Operations.Reloading

  defstruct []

  @type t() :: %__MODULE__{}

  @impl Wardrik.DeploymentOperation
  def subject(_request), do: Deployment.new()

  @impl Wardrik.DeploymentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(request, _caller) do
    case Wardrik.Definition.reloading() do
      [] -> {:error, Error.new(:unsupported, "This deployment reads no definitions again.")}
      nodes -> {:ok, Change.new(request, %Reloading{nodes: nodes})}
    end
  end

  @impl Wardrik.Command
  def make(%Change{effect: %Reloading{nodes: nodes} = effect}, _caller) do
    :ok = Wardrik.Definition.reload_on(nodes)
    {:ok, %{"reloaded" => Enum.map(nodes, &to_string/1)}, effect}
  end
end
