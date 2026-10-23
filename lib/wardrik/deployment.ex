defmodule Wardrik.Deployment do
  @moduledoc """
  The deployment itself: its nodes, and reading every agent's definition again.

      {:ok, %Wardrik.Nodes{nodes: [%Wardrik.Node{name: name, agents: count} | _rest]}} =
        Wardrik.Deployment.nodes(scope)
  """

  use Wardrik.Operations.Functions, prefix: "deployment"
end
