defmodule Wardrik.Authorizer do
  @moduledoc """
  Decides whether a scope may take an action on a resource.

      Wardrik.start_link(name: MyApp.AgentRuntime, authorizer: {MyApp.Authorizer, []})

  Wardrik asks once per operation, and once per agent for operations over many agents.
  `Wardrik.Statements` is used unless set.

  `c:authorize/4` returns:

    * `:ok` - allowed.
    * `{:error, :not_found}` - the scope can't reach the resource. Callers learn nothing about
      what they can't see.
    * `{:error, :forbidden}` - the scope reaches the resource but not the action.

  `c:holds?/3` is optional. It stops a scope from making a token wider than itself. Without it,
  a scope holds a statement if `c:authorize/4` allows each of its actions on each of its patterns.
  """

  alias Wardrik.Scope

  @doc "Decides whether `scope` may take `action`, such as `\"agent.ask\"`, on `resource`."
  @callback authorize(config :: term(), Scope.t(), action :: String.t(), resource :: String.t()) ::
              :ok | {:error, :forbidden | :not_found}

  @doc "Returns whether `scope` holds every action `statement` allows, on every resource it covers."
  @callback holds?(config :: term(), Scope.t(), Wardrik.Statement.t()) :: boolean()

  @optional_callbacks holds?: 3

  @doc "Returns whether `scope` holds everything `statement` allows. See `c:holds?/3`."
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

  @doc "Returns whether the operation running in `scope` may act on `resource`."
  @spec allows?(Scope.t(), String.t()) :: boolean()
  def allows?(%Scope{operation: %{action: action}} = scope, resource),
    do: authorize(scope, action, resource) == :ok

  @doc "Returns whether `scope` may take `action` on `resource`. See `c:authorize/4`."
  @spec authorize(Scope.t(), String.t(), String.t()) :: :ok | {:error, :forbidden | :not_found}
  def authorize(%Scope{wardrik: %{authorizer: {module, config}}} = scope, action, resource),
    do: module.authorize(config, scope, action, resource)

  def authorize(%Scope{wardrik: instance} = scope, action, resource),
    do: authorize(%{scope | wardrik: Wardrik.Instance.fetch!(instance)}, action, resource)
end
