defmodule Wardrik.Authorizer do
  @moduledoc """
  Says who may do what. Wardrik asks it before every operation.

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

  `c:authorize/2` gets a `Wardrik.Authorizer.Request`, and returns:

    * `:ok` - allowed.
    * `{:error, :not_found}` - the principal can't see the resource.
    * `{:error, :forbidden}` - they see it, but may not take the action.

  Operations over many agents ask once per agent.
  """

  alias Wardrik.Authorizer.Request
  alias Wardrik.Scope

  @doc "Decides the request."
  @callback authorize(Request.t(), opts :: term()) :: :ok | {:error, :forbidden | :not_found}

  @doc """
  Asks the authorizer whether `scope` may take `:action` on `:resource`.

      Wardrik.Authorizer.authorize(scope, action: "agent.ask", resource: {:agent, id})

  `:context` is merged over the scope's.
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
