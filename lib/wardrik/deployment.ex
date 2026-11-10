defmodule Wardrik.Deployment do
  @moduledoc """
  Operations on the deployment: listing its nodes, reading their resource use, and reloading
  every agent's definition.

      Wardrik.Deployment.nodes(scope)
      #=> {:ok, %Wardrik.Nodes{nodes: [%Wardrik.Node{name: "wardrik@box1", agents: 12}], asleep: 40}}
  """

  use Wardrik.Operations.Functions, prefix: "deployment"
end
