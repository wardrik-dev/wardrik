defmodule Wardrik.Agents do
  @moduledoc """
  Operations on every agent the scope can see.

      Wardrik.Agents.list(scope, agents: ["agt_01JF8X5RQ2"])
      #=> {:ok, [%Wardrik.Agent{id: "agt_01JF8X5RQ2", conversation: nil, status: :idle, ...}]}
  """

  use Wardrik.Operations.Functions, prefix: "agents"
end
