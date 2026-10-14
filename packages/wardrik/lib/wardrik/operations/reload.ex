defmodule Wardrik.Operations.Reload do
  @moduledoc """
  Has every node the host's `Wardrik.Definition` names in
  `c:Wardrik.Definition.reloading/0` read its definitions again, as
  `c:Wardrik.Definition.reload/0`, and bring the agents it runs to what
  they say now.
  """

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Deployment
  alias Wardrik.Error
  alias Wardrik.Host
  alias Wardrik.Operations.Reloading

  defstruct []

  @type t() :: %__MODULE__{}

  @impl Wardrik.DeploymentOperation
  def subject(_request), do: Deployment.new()

  @impl Wardrik.DeploymentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(request, caller) do
    case Wardrik.Definition.reloading(Host.definitions(caller.host)) do
      [] -> {:error, Error.new(:unsupported, "This deployment reads no definitions again.")}
      nodes -> {:ok, Change.new(request, %Reloading{nodes: nodes})}
    end
  end

  @impl Wardrik.Command
  def make(%Change{effect: %Reloading{nodes: nodes} = effect}, caller) do
    :ok = Wardrik.Definitions.reload_on(Host.definitions(caller.host), nodes)
    {:ok, %{"reloaded" => Enum.map(nodes, &to_string/1)}, effect}
  end
end
