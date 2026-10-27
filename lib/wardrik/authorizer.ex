defmodule Wardrik.Authorizer do
  @moduledoc """
  An authorizer decides whether a scope may take an action on a resource. Wardrik asks it once for
  each operation, and for each agent an operation over many covers.

  It answers `{:error, :not_found}` where nothing the scope holds reaches the resource, so a caller
  learns nothing of what it can't see, and `{:error, :forbidden}` where it reaches it without the
  action. `Wardrik.Statements` is the one Wardrik uses unless told otherwise.

  `holds?/3` says whether a scope holds everything a statement allows, so a token it makes is no
  wider than itself. An authorizer that doesn't implement it holds a statement where it allows each
  of its actions on each of its patterns, read as a resource's name.
  """

  alias Wardrik.Scope

  @doc "Decides whether `scope` may take `action`, like `agent.ask`, on `resource`."
  @callback authorize(config :: term(), Scope.t(), action :: String.t(), resource :: String.t()) ::
              :ok | {:error, :forbidden | :not_found}

  @doc "Says whether `scope` holds every action `statement` allows on every resource it covers."
  @callback holds?(config :: term(), Scope.t(), Wardrik.Statement.t()) :: boolean()

  @optional_callbacks holds?: 3

  @doc "Asks `scope`'s authorizer whether it holds everything `statement` allows."
  @spec holds?(Scope.t(), Wardrik.Statement.t()) :: boolean()
  def holds?(%Scope{wardrik: %{authorizer: {module, config}}} = scope, statement) do
    if function_exported?(module, :holds?, 3),
      do: module.holds?(config, scope, statement),
      else: each_allowed?(scope, statement)
  end

  def holds?(%Scope{wardrik: instance} = scope, statement),
    do: holds?(%{scope | wardrik: Wardrik.Instance.fetch!(instance)}, statement)

  defp each_allowed?(scope, %Wardrik.Statement{actions: actions, resources: resources}),
    do: Enum.all?(for(a <- actions, r <- resources, do: authorize(scope, a, r) == :ok))

  @doc "Asks `scope`'s authorizer whether it may take `action` on `resource`."
  @spec authorize(Scope.t(), String.t(), String.t()) :: :ok | {:error, :forbidden | :not_found}
  def authorize(%Scope{wardrik: %{authorizer: {module, config}}} = scope, action, resource),
    do: module.authorize(config, scope, action, resource)

  def authorize(%Scope{wardrik: instance} = scope, action, resource),
    do: authorize(%{scope | wardrik: Wardrik.Instance.fetch!(instance)}, action, resource)
end
