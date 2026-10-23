defmodule Wardrik.Deployment do
  @moduledoc """
  The deployment itself: its nodes, and reading every agent's definition again.

      Wardrik.Deployment.nodes(scope)
      #=> {:ok, %Wardrik.Nodes{nodes: [%Wardrik.Node{name: "wardrik@box1", agents: 12}], asleep: 40}}
  """

  use Wardrik.Operations.Functions, prefix: "deployment"
end
