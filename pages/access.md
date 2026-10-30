# Who may do what

Every operation runs in a scope: Wardrik, who acts, and what they're allowed. Nothing is allowed
unless it's granted.

## Scopes and grants

```elixir
scope = MyApp.Wardrik.as("acme/@maria", roles: [:reader, :messenger], resources: ["acme/agent/*"])

scope = Wardrik.grant(scope, roles: [:owner], resources: ["acme/@maria/*"])
```

`as/2` takes a principal and its grants. The principal is an ID, or a `WardrikCore.Principal` with
attributes your authorizer reads. The grants are one statement's options, or a list of
`Wardrik.Statement`s. `Wardrik.grant/2` adds one more statement.

A statement allows actions on resources, as IAM statements do:

| Thing | Resource |
| --- | --- |
| The agent `acme/books` | `acme/agent/books` |
| The agent `acme/@jon/notes` | `acme/@jon/agent/notes` |
| The org's MCP server `linear` | `acme/mcp_server/linear` |
| Jon's GitHub account | `acme/@jon/connection/github` |
| Tokens, nodes, the audit, reloading | `deployment` |

| Role | Actions |
| --- | --- |
| `:reader` | `agent.read`, `agent.events`, `connection.read`, `mcp_server.read`, `ceiling.read` |
| `:messenger` | `agent.ask`, `agent.cancel`, `agent.clear` |
| `:approver` | `agent.decide` |
| `:definer` | `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget`, `connection.connect`, `mcp_server.add` |
| `:worker` | `agent.serve`, to offer tools to the agents it covers |
| `:owner` | every action |

An agent no statement reaches is invisible to the scope. Operations on it return `not_found`, and
lists leave it out. An agent a statement reaches, without the action, returns `forbidden`.

## API tokens

People and programs reach Wardrik over HTTP with a token. The secret is returned once, when the
token is made:

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

A token acts for whoever made it, and is stored as the SHA-256 of its secret.

### Options

  * `:name` - required. What it's listed as.
  * `:roles` - required. What it may do.
  * `:resources` - required. Resource patterns it reaches.
  * `:expires_in` - seconds it works for. 90 days unless set.
  * `:policy` - a policy every agent it defines is held to, ahead of the agent's own. A definition
    can narrow it, never widen it.

`Wardrik.Tokens.list/2` lists tokens. With `resources:`, it lists only those whose every resource
the patterns cover, so `["acme/agent/*"]` lists tokens over acme's own agents.
`Wardrik.Tokens.revoke/3` refuses a token from then on. Agents it defined keep running, under the
policy they were defined with.

### No wider than its maker

A token can't do more than whoever makes it:

  * Each action its roles allow, on each resource it names, must be one its maker may take there.
  * A token made by someone held to a policy is held to it too.
  * A token made by a token expires no later than that token.

So an org admin holding `deployment.tokens` and their org's statements makes tokens over their org
alone:

```elixir
keeper = Wardrik.Statement.new(actions: ["deployment.tokens"], resources: ["deployment"])
team = Wardrik.Statement.new(roles: [:reader, :messenger], resources: ["acme/agent/*"])
admin = MyApp.Wardrik.as("acme/@maria", [keeper, team])

{:ok, _issued} =
  Wardrik.Tokens.create(admin, name: "ci", roles: ["messenger"], resources: ["acme/agent/deploy"])

Wardrik.Tokens.create(admin, name: "wide", roles: ["definer"], resources: ["acme/agent/*"])
#=> {:error, %Wardrik.Error{type: :forbidden, message: "A token can't do more than the one that makes it, on more of it."}}
```

## Write your own authorizer

Use one when your app already decides who may do what:

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

`authorize/4` returns:

  * `:ok` - allowed.
  * `{:error, :not_found}` - the scope can't see the resource.
  * `{:error, :forbidden}` - it can see it, but lacks the action.

The grants you gave are in the scope's `grants`. Implement the optional `holds?/3` to decide which
tokens a scope may make; see `Wardrik.Authorizer`.
