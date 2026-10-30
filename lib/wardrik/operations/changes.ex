defmodule Wardrik.Operations.Changes do
  @moduledoc "Records changes made through Wardrik in the audit, with who made them."

  alias Wardrik.Scope

  @doc "Records a change of `type`, such as `\"agent.defined\"`, to the agent `id`."
  @spec record(Scope.t(), String.t(), String.t(), map()) :: :ok
  def record(%Scope{wardrik: wardrik, principal: principal}, type, id, data \\ %{}) do
    change = {type, "agents/" <> id, Map.put(data, "agent", %{"id" => id})}
    :ok = WardrikEvents.record(Wardrik.events(wardrik), change, actor: principal)
  end

  @doc "Records a change of `type`, such as `\"server.added\"`, to something `owner` holds."
  @spec record_owned(Scope.t(), String.t(), String.t(), String.t(), map()) :: :ok
  def record_owned(%Scope{wardrik: wardrik, principal: principal}, type, owner, subject, data) do
    change = {type, subject, Map.put(data, "owner", owner)}
    :ok = WardrikEvents.record(Wardrik.events(wardrik), change, actor: principal)
  end

  @doc "Records a change of `type`, such as `\"token.created\"`, to the deployment."
  @spec record_deployment(Scope.t(), String.t(), String.t(), map()) :: :ok
  def record_deployment(%Scope{wardrik: wardrik, principal: principal}, type, subject, data) do
    :ok = WardrikEvents.record(Wardrik.events(wardrik), {type, subject, data}, actor: principal)
  end
end
