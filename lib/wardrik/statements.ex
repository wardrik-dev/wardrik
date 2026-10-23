defmodule Wardrik.Statements do
  @moduledoc """
  The authorizer that decides by the `Wardrik.Statement`s a scope holds as its grants. Anything no
  statement allows is refused.

      scope = Wardrik.as(wardrik, principal, [Wardrik.Statement.new(roles: [:reader], resources: ["acme/agent/*"])])
  """

  @behaviour Wardrik.Authorizer

  alias Wardrik.Scope
  alias Wardrik.Statement
  alias WardrikEvents.Pattern

  @impl Wardrik.Authorizer
  def authorize(_config, %Scope{grants: statements}, action, resource) do
    reaching = Enum.filter(statements, &reaches?(&1, resource))

    cond do
      reaching == [] -> {:error, :not_found}
      Enum.any?(reaching, &allows?(&1, action)) -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp reaches?(%Statement{resources: patterns}, resource),
    do: Enum.any?(patterns, &Pattern.covers?(&1, resource))

  defp allows?(%Statement{actions: actions}, action),
    do: Enum.any?(actions, &Pattern.covers?(&1, action))
end
