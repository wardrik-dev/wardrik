defmodule Wardrik.Authorizer do
  @moduledoc """
  Decides whether a principal may take an action on a resource, as Cedar's requests do.

      Wardrik.start_link(name: MyApp.AgentRuntime, authorizer: {MyApp.Authorizer, []})

      defmodule MyApp.Authorizer do
        @behaviour Wardrik.Authorizer

        @impl true
        def authorize(%{action: "agent." <> _verb, resource: {:agent, id}} = request, _opts) do
          if MyApp.Agents.member?(id, request.principal.id),
            do: :ok,
            else: {:error, :not_found}
        end

        def authorize(_request, _opts), do: {:error, :forbidden}
      end

  Wardrik asks once per operation, and once per agent for operations over many agents, with a
  `Wardrik.Authorizer.Request`. `Wardrik.Statements` decides unless set.

  `c:authorize/2` returns:

    * `:ok` - allowed.
    * `{:error, :not_found}` - the principal can't reach the resource. Callers learn nothing
      about what they can't see.
    * `{:error, :forbidden}` - the principal reaches the resource but not the action.
  """

  alias Wardrik.Authorizer.Request
  alias Wardrik.Scope

  @doc "Decides whether the request's principal may take its action on its resource."
  @callback authorize(Request.t(), opts :: term()) :: :ok | {:error, :forbidden | :not_found}

  @doc """
  Returns whether `scope` may take an action on a resource.

      Wardrik.Authorizer.authorize(scope, action: "agent.ask", resource: {:agent, id})

  Takes the `Wardrik.Authorizer.Request` fields but `:principal` and `:scope`, which are the
  scope's.
  """
  @spec authorize(Scope.t(), keyword()) :: :ok | {:error, :forbidden | :not_found}
  def authorize(%Scope{wardrik: %{authorizer: {module, opts}}} = scope, fields),
    do:
      module.authorize(
        struct!(Request, [principal: scope.principal, scope: scope] ++ fields),
        opts
      )

  def authorize(%Scope{wardrik: instance} = scope, fields),
    do: authorize(%{scope | wardrik: Wardrik.Instance.fetch!(instance)}, fields)

  @doc "Returns whether the operation running in `scope` may act on `resource`."
  @spec allows?(Scope.t(), Request.resource()) :: boolean()
  def allows?(%Scope{operation: %{action: action}} = scope, resource),
    do: authorize(scope, action: action, resource: resource) == :ok

  @doc """
  Returns whether `scope` holds everything `statement` allows, so a token it makes is no wider
  than itself. Only `Wardrik.Statements` says, so with another authorizer, no scope makes tokens.
  """
  @spec holds?(Scope.t(), Wardrik.Statement.t()) :: boolean()
  def holds?(%Scope{wardrik: %{authorizer: {Wardrik.Statements, _opts}}} = scope, statement),
    do: Wardrik.Statements.holds?(scope, statement)

  def holds?(%Scope{wardrik: %{authorizer: _other}}, _statement), do: false

  def holds?(%Scope{wardrik: instance} = scope, statement),
    do: holds?(%{scope | wardrik: Wardrik.Instance.fetch!(instance)}, statement)
end
