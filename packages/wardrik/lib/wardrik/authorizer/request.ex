defmodule Wardrik.Authorizer.Request do
  @moduledoc """
  What `c:Wardrik.Authorizer.authorize/2` decides.

      %Wardrik.Authorizer.Request{
        principal: %Wardrik.Principal{id: "user_42"},
        actor: {:agent, "agt_01JF8"},
        action: "agent.ask",
        resource: {:agent, "agt_01JF9"},
        scope: scope
      }

  ## Fields

    * `:principal` - who it's for, as RFC 8693's `sub`.
    * `:actor` - who acts for them, as RFC 8693's `act`, or `nil` for the principal itself:
      * `{:agent, id}` - an agent's tools, or its answer to another agent. The principal is its
        resolved one.
      * `{:channel, name}` - a chat member, as `Wardrik.Chat.Identities` names them, or the
        installation's owner for what the channel does itself.
    * `:action` - as `"agent.ask"`.
    * `:resource` - `{:agent, id}`, `{:deployment, name}`, or another `{kind, id}` your app checks.
    * `:scope` - the `Wardrik.Scope`.
    * `:context` - the scope's context. A channel gives `:installation`, and `:asked_by` when
      deciding. An operation on a conversation gives `:conversation`; its resource is the agent.
  """

  alias Wardrik.Principal
  alias Wardrik.Scope

  @enforce_keys [:principal, :action, :resource, :scope]
  defstruct [:principal, :actor, :action, :resource, :scope, context: %{}]

  @typedoc "What an action acts on, by kind and ID."
  @type resource() ::
          {:agent, String.t()}
          | {:deployment, String.t()}
          | {atom(), String.t()}

  @type t() :: %__MODULE__{
          principal: Principal.t(),
          actor: Scope.actor(),
          action: String.t(),
          resource: resource(),
          scope: Scope.t(),
          context: map()
        }
end
