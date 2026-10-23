defmodule Wardrik.Operations.Changes do
  @moduledoc """
  Records in the audit what people change through Wardrik, and who changed it.
  """

  alias Wardrik.Scope

  @doc "Records the change `type`, like `agent.defined`, that `scope` made to the agent `id`."
  @spec record(Scope.t(), String.t(), String.t(), map()) :: :ok
  def record(%Scope{wardrik: wardrik, principal: principal}, type, id, data \\ %{}) do
    change = {type, "agents/" <> id, Map.put(data, "agent", %{"id" => id})}
    :ok = WardrikEvents.record(Wardrik.events(wardrik), change, actor: principal)
  end
end
