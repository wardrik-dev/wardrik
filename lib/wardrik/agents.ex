defmodule Wardrik.Agents do
  @moduledoc """
  The operations on the agents a scope can see.

      {:ok, %{"agents" => agents}} = Wardrik.Agents.list(scope, %{"resources" => ["acme/agent/*"]})
  """

  use Wardrik.Operations.Functions, prefix: "agents"
end
