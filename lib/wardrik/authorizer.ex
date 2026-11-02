defmodule Wardrik.Authorizer do
  @moduledoc """
  Decides whether a principal may take an action on a resource, as Cedar's requests do.

      Wardrik.start_link(name: MyApp.AgentRuntime, authorizer: {MyApp.Authorizer, []})

      defmodule MyApp.Authorizer do
        @behaviour Wardrik.Authorizer

        @impl true
        def authorize(principal, "agent." <> _verb, {:agent, id}, _context, _config) do
          if MyApp.Agents.member?(id, principal.id), do: :ok, else: {:error, :not_found}
        end

        def authorize(_principal, _action, _resource, _context, _config), do: {:error, :forbidden}
      end

  A resource is `{kind, id}`:

    * `{:agent, id}` - the agent `id`, as your app named it. Wardrik never reads it.
    * `{:deployment, name}` - the deployment, by `Wardrik`'s `:deployment`.
    * `{:owner, owner}` - an owner's providers, servers, notify targets, secrets, connections and
      ceilings, with the item's `name` in the context. These operations move to `WardrikDaemon`.

  Your app knows which org or person each agent belongs to, so the resource names nothing else.

  The context holds the `:scope` acting, with its `grants`, and, for an owner's item, its
  `:name`. Wardrik asks once per operation, and once per agent for operations over many agents.
  `Wardrik.Statements` is used unless set.

  `c:authorize/5` returns:

    * `:ok` - allowed.
    * `{:error, :not_found}` - the principal can't reach the resource. Callers learn nothing
      about what they can't see.
    * `{:error, :forbidden}` - the principal reaches the resource but not the action.

  `c:holds?/3` is optional. It stops a scope from making a token wider than itself. Without it,
  no scope makes tokens.
  """

  alias Wardrik.Scope
  alias WardrikCore.Principal

  @typedoc "What an action acts on, by kind and ID."
  @type resource() :: {:agent, String.t()} | {:deployment, String.t()} | {:owner, String.t()}

  @typedoc "What else Wardrik knows of the request: the `:scope` acting, and an item's `:name`."
  @type context() :: %{required(:scope) => Scope.t(), optional(:name) => String.t() | nil}

  @doc "Decides whether `principal` may take `action`, such as `\"agent.ask\"`, on `resource`."
  @callback authorize(
              principal :: Principal.t(),
              action :: String.t(),
              resource :: resource(),
              context :: context(),
              config :: term()
            ) :: :ok | {:error, :forbidden | :not_found}

  @doc "Returns whether `scope` holds every action `statement` allows, on every resource it covers."
  @callback holds?(config :: term(), Scope.t(), Wardrik.Statement.t()) :: boolean()

  @optional_callbacks holds?: 3

  @doc "Returns whether `scope` holds everything `statement` allows. See `c:holds?/3`."
  @spec holds?(Scope.t(), Wardrik.Statement.t()) :: boolean()
  def holds?(%Scope{wardrik: %{authorizer: {module, config}}} = scope, statement),
    do: function_exported?(module, :holds?, 3) and module.holds?(config, scope, statement)

  def holds?(%Scope{wardrik: instance} = scope, statement),
    do: holds?(%{scope | wardrik: Wardrik.Instance.fetch!(instance)}, statement)

  @doc "Returns whether the operation running in `scope` may act on `resource`."
  @spec allows?(Scope.t(), resource()) :: boolean()
  def allows?(%Scope{operation: %{action: action}} = scope, resource),
    do: authorize(scope, action, resource) == :ok

  @doc "Returns whether `scope` may take `action` on `resource`. See `c:authorize/5`."
  @spec authorize(Scope.t(), String.t(), resource(), map()) ::
          :ok | {:error, :forbidden | :not_found}
  def authorize(scope, action, resource, context \\ %{})

  def authorize(
        %Scope{wardrik: %{authorizer: {module, config}}} = scope,
        action,
        resource,
        context
      ),
      do:
        module.authorize(
          scope.principal,
          action,
          resource,
          Map.put(context, :scope, scope),
          config
        )

  def authorize(%Scope{wardrik: instance} = scope, action, resource, context),
    do:
      authorize(%{scope | wardrik: Wardrik.Instance.fetch!(instance)}, action, resource, context)
end
