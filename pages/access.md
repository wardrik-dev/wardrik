# Who may do what

Every operation runs in a scope: the Wardrik, who acts, and what they're allowed. Nothing is allowed
unless it's granted.

## Scopes and grants

```elixir
scope = MyApp.Wardrik.as("acme/@maria", roles: [:reader, :messenger], resources: ["acme/agent/*"])

scope = Wardrik.grant(scope, roles: [:owner], resources: ["acme/@maria/*"])
```

`as/2` takes a principal by id, or a `WardrikCore.Principal` with attributes your authorizer reads,
and grants: the options of one statement, or a list of `Wardrik.Statement`s. `Wardrik.grant/2` adds
one more.

A statement allows actions on resources, as IAM's do. The agent `acme/books` is the resource
`acme/agent/books`, and `acme/@jon/notes` is `acme/@jon/agent/notes`. What an owner holds is under
them too: `acme/mcp_server/linear` is the org's server, and `acme/@jon/connection/github` is Jon's
account. The deployment's own operations, its tokens, nodes, audit and reloading, are on
`deployment`.

| Role | Actions |
| --- | --- |
| `:reader` | `agent.read`, `agent.events`, `connection.read`, `mcp_server.read`, `ceiling.read` |
| `:messenger` | `agent.ask`, `agent.cancel`, `agent.clear` |
| `:approver` | `agent.decide` |
| `:definer` | `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget`, `connection.connect`, `mcp_server.add` |
| `:owner` | every action |

Notice that an agent no statement reaches is one the scope can't see: operations on it answer
`not_found`, and lists leave it out. An agent a statement reaches without the action answers
`forbidden`.

## API tokens

People and programs reaching Wardrik over HTTP present a token. Make one, and its secret is given
this once:

```elixir
{:ok, issued} =
  Wardrik.Tokens.create(scope, name: "ci", roles: ["reader", "messenger"], resources: ["acme/agent/*"])
#=> {:ok,
#=>  %Wardrik.TokenIssued{
#=>    token: %Wardrik.Token{
#=>      id: "3f9a61c0d4e2",
#=>      name: "ci",
#=>      principal: "acme/@maria",
#=>      statements: [%Wardrik.Statement{actions: ["agent.read", ...], resources: ["acme/agent/*"]}],
#=>      expires: ~U[2027-01-21 09:00:00Z],
#=>      ...
#=>    },
#=>    secret: "wrk_3f9a61c0d4e2_9c1e..."
#=>  }}

{:ok, ci} = MyApp.Wardrik.authenticate(issued.secret)
```

A token acts for whoever made it, works for 90 days unless `expires_in` says, and is kept as the
SHA-256 of its secret. `policy:` names a policy every agent it defines is held to, ahead of the
agent's own: a definition can narrow it, never widen it. `Wardrik.Tokens.list/2` lists them, or
with `resources:` only those whose every resource the patterns cover, as `["acme/agent/*"]` lists
acme's own. `Wardrik.Tokens.revoke/2` refuses one from then on.

A token is never wider than whoever makes it. Each action its roles allow, on each resource it
names, is one its maker may take there, so an org's admin, holding `deployment.tokens` and their
org's statements, makes tokens over their org alone. A token made by one held to a policy is held
to it too, and one made by a token expires no later than that token does:

```elixir
keeper = Wardrik.Statement.new(actions: ["deployment.tokens"], resources: ["deployment"])
admin = MyApp.Wardrik.as("acme/@maria", [keeper, Wardrik.Statement.new(roles: [:reader, :messenger], resources: ["acme/agent/*"])])

{:ok, _issued} = Wardrik.Tokens.create(admin, name: "ci", roles: ["messenger"], resources: ["acme/agent/deploy"])
Wardrik.Tokens.create(admin, name: "wide", roles: ["definer"], resources: ["acme/agent/*"])
#=> {:error, %Wardrik.Error{type: :forbidden, message: "A token can't do more than the one that makes it, on more of it."}}
```

## Write your own authorizer

Reach for this when your app already decides who may do what:

```elixir
defmodule MyApp.Authorizer do
  @behaviour Wardrik.Authorizer

  @impl true
  def authorize(_config, %Wardrik.Scope{principal: principal}, action, resource) do
    MyApp.Permissions.check(principal.id, action, resource)
  end
end

config :my_app, MyApp.Wardrik, authorizer: {MyApp.Authorizer, []}
```

It answers `:ok`, `{:error, :not_found}` where the scope can't see the resource, or
`{:error, :forbidden}` where it can without the action. Your grants are in the scope's `grants`, as
you gave them.
