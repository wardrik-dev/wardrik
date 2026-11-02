# Access

Every operation runs in a scope: Wardrik, who acts, and what they're allowed. Nothing is allowed
unless it's granted.

> See it in action: [Who may do what](../notebooks/access-demo.livemd)

## Setup

In a fresh IEx session:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.2"}])

{:ok, _} = Wardrik.start_link(name: MyApp.AgentRuntime)
scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria", roles: [:owner], resources: ["acme/@maria/*"])

{:ok, _} = Wardrik.Agent.define(scope, "acme/@maria/books", model: "anthropic:claude-haiku-4-5")
```

## Scopes and grants

`Wardrik.as/3` takes Wardrik, a principal and its grants. Here Jon may read and message Maria's
agents:

```elixir
jon =
  Wardrik.as(MyApp.AgentRuntime, "acme/@jon",
    roles: [:reader, :messenger],
    resources: ["acme/@maria/agent/*"]
  )

{:ok, _agent} = Wardrik.Agent.read(jon, "acme/@maria/books")

Wardrik.Agent.stop(jon, "acme/@maria/books")
#=> {:error, %Wardrik.Error{type: :forbidden, message: "You may not do this to the agent acme/@maria/books."}}

jon = Wardrik.grant(jon, roles: [:definer], resources: ["acme/@maria/agent/books"])

{:ok, _agent} = Wardrik.Agent.stop(jon, "acme/@maria/books")
```

The principal is an ID, or a `Wardrik.principal/2` with attributes your authorizer reads. The
grants are one statement's options, or a list of `Wardrik.Statement`s. `Wardrik.grant/2` adds one
more statement.

A statement allows actions on resources, as IAM statements do:

| Thing | Resource |
| --- | --- |
| The agent `acme/books` | `acme/agent/books` |
| The agent `acme/@maria/books` | `acme/@maria/agent/books` |
| The org's MCP server `linear` | `acme/mcp_server/linear` |
| Maria's GitHub account | `acme/@maria/connection/github` |
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
lists leave it out. An agent a statement reaches, without the action, returns `forbidden`:

```elixir
sam = Wardrik.as(MyApp.AgentRuntime, "acme/@sam")

Wardrik.Agent.read(sam, "acme/@maria/books")
#=> {:error, %Wardrik.Error{type: :not_found, message: "There's no agent acme/@maria/books."}}
```

## API tokens

People and programs reach Wardrik over HTTP with a token. Making one needs `deployment.tokens` on
`deployment`. The secret is returned once, when the token is made:

```elixir
admin = Wardrik.grant(scope, actions: ["deployment.tokens"], resources: ["deployment"])

{:ok, issued} =
  Wardrik.Tokens.create(admin,
    name: "ci",
    roles: ["reader", "messenger"],
    resources: ["acme/@maria/agent/*"]
  )
#=> {:ok,
#=>  %Wardrik.TokenIssued{
#=>    token: %Wardrik.Token{
#=>      id: "3f9a61c0d4e2",
#=>      name: "ci",
#=>      principal: "acme/@maria",
#=>      statements: [%Wardrik.Statement{actions: ["agent.read", ...], resources: ["acme/@maria/agent/*"]}],
#=>      expires: ~U[2027-01-28 18:00:00Z],
#=>      ...
#=>    },
#=>    secret: "wrk_3f9a61c0d4e2_9c1e..."
#=>  }}

{:ok, ci} = Wardrik.authenticate(MyApp.AgentRuntime, issued.secret)

{:ok, _agent} = Wardrik.Agent.read(ci, "acme/@maria/books")
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
the patterns cover:

```elixir
{:ok, [%Wardrik.Token{name: "ci"}]} = Wardrik.Tokens.list(admin, resources: ["acme/@maria/*"])
```

`Wardrik.Tokens.revoke/3` refuses a token from then on. Agents it defined keep running, under the
policy they were defined with:

```elixir
{:ok, _token} = Wardrik.Tokens.revoke(admin, issued.token)

Wardrik.authenticate(MyApp.AgentRuntime, issued.secret)
#=> {:error, %Wardrik.Error{type: :unauthorized, ...}}
```

### No wider than its maker

A token can't do more than whoever makes it:

  * Each action its roles allow, on each resource it names, must be one its maker may take there.
  * A token made by someone held to a policy is held to it too.
  * A token made by a token expires no later than that token.

So `admin`, who owns `acme/@maria/*` alone, makes tokens over it alone:

```elixir
Wardrik.Tokens.create(admin, name: "wide", roles: ["definer"], resources: ["acme/agent/*"])
#=> {:error, %Wardrik.Error{type: :forbidden, message: "A token can't do more than the one that makes it, on more of it."}}
```

## Write your own authorizer

Use one when your app already decides who may do what. Your app knows who owns each agent, so it
looks that up, never reading it from the ID. This one keeps owners in a map:

```elixir
defmodule MyApp.Authorizer do
  @behaviour Wardrik.Authorizer

  @owners %{"acme/books" => "user_maria"}

  @impl true
  def authorize(%Wardrik.Authorizer.Request{principal: principal, resource: {:agent, id}}, _opts) do
    if Map.get(@owners, id) == principal.id, do: :ok, else: {:error, :not_found}
  end

  def authorize(_request, _opts), do: {:error, :forbidden}
end
```

Start Wardrik with it, in a fresh IEx session:

```elixir
{:ok, _} = Wardrik.start_link(name: MyApp.AgentRuntime, authorizer: {MyApp.Authorizer, []})
scope = Wardrik.as(MyApp.AgentRuntime, "user_maria")

Wardrik.Agent.define(scope, "acme/books", model: "anthropic:claude-haiku-4-5")
#=> {:ok, %Wardrik.Agent{id: "acme/books", ...}}

Wardrik.Agent.define(scope, "acme/triage", model: "anthropic:claude-haiku-4-5")
#=> {:error, %Wardrik.Error{type: :not_found, message: "There's no agent acme/triage."}}
```

`authorize/2` takes a `Wardrik.Authorizer.Request`: the principal, the action, the resource as
`{kind, id}`, and the scope, with the grants you gave. It returns:

  * `:ok` - allowed.
  * `{:error, :not_found}` - the principal can't see the resource.
  * `{:error, :forbidden}` - it can see it, but lacks the action.

Only `Wardrik.Statements` lets a scope make tokens.
