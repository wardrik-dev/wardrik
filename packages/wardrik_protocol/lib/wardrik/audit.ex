defmodule Wardrik.Audit do
  @moduledoc """
  Operations on the deployment's audit log.

      Wardrik.Audit.list(scope, limit: 50)
      #=> {:ok, %Wardrik.Page{events: [%Wardrik.Event{type: "wardrik.agent.defined", ...}], next: 1}}
  """

  use Wardrik.Operations.Functions, prefix: "audit"
end
