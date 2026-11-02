defmodule Wardrik.Authorizer do
  @moduledoc """
  Decides whether a principal may take an action on a resource, as Cedar's requests do.

      Wardrik.start_link(name: MyApp.AgentRuntime, authorizer: {MyApp.Authorizer, []})

      defmodule MyApp.Authorizer do
        @behaviour Wardrik.Authorizer

        @impl true
        def authorize(%{actor: {:agent, _id}, action: "agent.forget"}, _opts),
          do: {:error, :forbidden}

        def authorize(%{action: "agent." <> _verb, resource: {:agent, id}} = request, _opts) do
          if MyApp.Agents.member?(id, request.principal.id),
            do: :ok,
            else: {:error, :not_found}
        end

        def authorize(_request, _opts), do: {:error, :forbidden}
      end

  Wardrik requires one. It asks once per operation, and once per agent for operations over many
  agents, with a `Wardrik.Authorizer.Request`.

  `c:authorize/2` returns:

    * `:ok` - allowed.
    * `{:error, :not_found}` - the principal can't reach the resource. Callers learn nothing
      about what they can't see.
    * `{:error, :forbidden}` - the principal reaches the resource but not the action.
  """

  alias Wardrik.Authorizer.Request
  alias Wardrik.Scope

  @doc "Decides whether the request's principal, through its actor, may take its action on its resource."
  @callback authorize(Request.t(), opts :: term()) :: :ok | {:error, :forbidden | :not_found}

  @doc """
  Returns whether `scope` may take an action on a resource.

      Wardrik.Authorizer.authorize(scope, action: "agent.ask", resource: {:agent, id})

  Takes the `Wardrik.Authorizer.Request` fields but `:principal`, `:actor` and `:scope`, which
  are the scope's. `:context` is merged over the scope's.
  """
  @spec authorize(Scope.t(), keyword()) :: :ok | {:error, :forbidden | :not_found}
  def authorize(%Scope{wardrik: %{authorizer: {module, opts}}} = scope, fields) do
    {context, fields} = Keyword.pop(fields, :context, %{})

    module.authorize(
      struct!(
        Request,
        [
          principal: scope.principal,
          actor: scope.actor,
          scope: scope,
          context: Map.merge(scope.context, context)
        ] ++ fields
      ),
      opts
    )
  end

  def authorize(%Scope{wardrik: instance} = scope, fields),
    do: authorize(%{scope | wardrik: Wardrik.Instance.fetch!(instance)}, fields)

  @doc "Returns whether the operation running in `scope` may act on `resource`."
  @spec allows?(Scope.t(), Request.resource()) :: boolean()
  def allows?(%Scope{operation: %{action: action}} = scope, resource),
    do: authorize(scope, action: action, resource: resource) == :ok
end
