defmodule Wardrik.Operations.Deployment do
  @moduledoc "The operations on the deployment itself."

  @doc "Reads a page of what people changed across the deployment."
  @spec audit(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def audit(scope, input) do
    opts = [after: input["starting_after"] || 0, limit: input["limit"] || 100]
    %{events: events, next: next} = WardrikEvents.audit(Wardrik.events(scope.wardrik), opts)
    {:ok, %{"events" => events, "next" => next}}
  end
end
