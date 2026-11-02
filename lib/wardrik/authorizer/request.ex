defmodule Wardrik.Authorizer.Request do
  @moduledoc """
  What `c:Wardrik.Authorizer.authorize/2` decides: whether `principal` may take `action` on
  `resource`.

      %Wardrik.Authorizer.Request{
        principal: %WardrikCore.Principal{id: "user_42"},
        action: "agent.ask",
        resource: {:agent, "agt_01JF8"},
        scope: scope
      }

  ## Fields

    * `:principal` - who is acting.
    * `:action` - what they do, as `"agent.ask"`.
    * `:resource` - what it acts on, as `{kind, id}`:
      * `{:agent, id}` - the agent `id`, as your app named it. Wardrik never reads it.
      * `{:deployment, name}` - the deployment, by `Wardrik`'s `:deployment`.
      * `{:owner, owner}` - an owner's providers, servers, notify targets, secrets, connections
        and ceilings. These operations move to `WardrikDaemon`.
    * `:scope` - the `Wardrik.Scope` acting, with its `grants`.
    * `:context` - what else the request carries, as an owner's item's `:name`.

  Your app knows which org or person each agent belongs to, so the resource names nothing else.
  """

  alias Wardrik.Scope
  alias WardrikCore.Principal

  @enforce_keys [:principal, :action, :resource, :scope]
  defstruct [:principal, :action, :resource, :scope, context: %{}]

  @typedoc "What an action acts on, by kind and ID."
  @type resource() :: {:agent, String.t()} | {:deployment, String.t()} | {:owner, String.t()}

  @type t() :: %__MODULE__{
          principal: Principal.t(),
          action: String.t(),
          resource: resource(),
          scope: Scope.t(),
          context: map()
        }
end
