defmodule Wardrik.Agents do
  @moduledoc """
  Operations on every agent the scope can see.

      Wardrik.Agents.list(scope, agents: ["agt_1"])
      #=> {:ok, [%Wardrik.Agent{id: "agt_1", conversation: nil, status: :idle, ...}]}
  """

  use Wardrik.Operations.Functions, prefix: "agents"
end
