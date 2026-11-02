defmodule Wardrik.Authorizer.Request do
  @moduledoc """
  What `c:Wardrik.Authorizer.authorize/2` decides: whether `actor`, for `principal`, may take
  `action` on `resource`.

      %Wardrik.Authorizer.Request{
        principal: %WardrikCore.Principal{id: "user_42"},
        actor: {:agent, "agt_01JF8"},
        action: "agent.ask",
        resource: {:agent, "agt_01JF9"},
        scope: scope
      }

  ## Fields

    * `:principal` - on whose behalf it acts, as RFC 8693's `sub`.
    * `:actor` - who acts, as RFC 8693's `act`, or `nil` when the principal acts directly:
      * `{:agent, id}` - an agent, through its own tools or answering another agent. The
        principal is the one its `Wardrik.Resolver` gives it.
      * `{:channel, name}` - a chat app's channel, for a member of a workspace it's added to.
        The principal is the member's.
    * `:action` - what they do, as `"agent.ask"`.
    * `:resource` - what it acts on, as `{kind, id}`:
      * `{:agent, id}` - the agent `id`, as your app named it. Wardrik never reads it.
      * `{:deployment, name}` - the deployment, by `Wardrik`'s `:deployment`.
      * `{:owner, owner}` - an owner's OAuth apps and connected accounts.
      * `{kind, id}` - anything else your app authorizes through its authorizer, as
        `WardrikDaemon` does its own routes'.
    * `:scope` - the `Wardrik.Scope` acting.
    * `:context` - what else the request carries: an owner's item's `:name`, and what the actor
      knows. A channel gives `:asked_by`, the principal ID that asked in the conversation, where
      known, `:approver`, whether the member is one of the installation's approvers, and
      `:installation`, as `%{owner: owner, workspace: workspace}`.

  Your app knows which org or person each agent belongs to, so the resource names nothing else.
  """

  alias Wardrik.Scope
  alias WardrikCore.Principal

  @enforce_keys [:principal, :action, :resource, :scope]
  defstruct [:principal, :actor, :action, :resource, :scope, context: %{}]

  @typedoc "What an action acts on, by kind and ID."
  @type resource() ::
          {:agent, String.t()}
          | {:deployment, String.t()}
          | {:owner, String.t()}
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
