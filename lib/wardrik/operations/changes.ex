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

  @doc "Records the change `type`, like `server.added`, that `scope` made to what `owner` holds."
  @spec record_owned(Scope.t(), String.t(), String.t(), String.t(), map()) :: :ok
  def record_owned(%Scope{wardrik: wardrik, principal: principal}, type, owner, subject, data) do
    change = {type, subject, Map.put(data, "owner", owner)}
    :ok = WardrikEvents.record(Wardrik.events(wardrik), change, actor: principal)
  end
end
