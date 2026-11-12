# MCP servers

> See it in action: [Configure agent tools](../notebooks/tools-demo.livemd)

Agents call MCP servers' tools. Your resolver selects the servers available to each agent.

## Setup

Nothing here calls a model. Adding a server reaches it over the network.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.11"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer
  def authorize(_request, _opts), do: :ok
end

# Every agent works for Maria, and reaches DeepWiki, and Linear once it's added.
defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver

  def resolve(_request, _opts) do
    {:ok,
     %Wardrik.Resolved{
       principal: Wardrik.principal("maria"),
       servers: %{"deepwiki" => "deepwiki", "linear" => "acme:linear"}
     }}
  end
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []},
    mcp: [deepwiki: [transport: {:streamable_http, url: "https://mcp.deepwiki.com/mcp"}]]
  )

scope = Wardrik.as(MyApp.AgentRuntime, "maria")
```

## Servers Wardrik starts with

`:mcp` starts servers. A definition names a server's tools as `deepwiki/*`:

```elixir
{:ok, _} =
  Wardrik.Agent.define(scope, "agt_assistant",
    model: "anthropic:claude-haiku-4-5",
    tools: ["deepwiki/*", "linear/*"]
  )

Wardrik.Agent.definition(scope, "agt_assistant")
#=> {:ok, %Wardrik.Definition{tools: ["deepwiki/*", "linear/*"], ...}, ["linear/*"]}
```

- The last element lists servers it names that aren't there yet.
- An agent can call only the servers configured by its resolver's `servers` map.
- `servers/*` gives every server it's resolved with.
- With `credential_name: "github"`, a server is reached with each person's own account. See
  [Credentials](credentials.md).
- See `Wardrik.MCP.Server` for every server option.

## Servers your app adds

Add a server while Wardrik runs, then configure access through your resolver:

```elixir
:ok =
  Wardrik.MCP.add(Wardrik.mcp(MyApp.AgentRuntime), "acme:linear",
    transport: {:streamable_http, url: "https://mcp.linear.app/mcp"},
    prefix: "linear"
  )
```

- Every node reaches it, from the store.
- Agents see it from their next turn.
- The URL must be `https` at a public address. Wardrik's `:egress` option changes that.
- A server's answers come from outside. Hold its tools to a [policy](policies.md).

## Server options

```elixir
mcp: [
  github: [
    transport:
      {:stdio,
       command: "github-mcp-server",
       args: ["stdio"],
       env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => System.fetch_env!("GITHUB_TOKEN")}},
    only: ["search_issues", "create_issue"]
  ],
  crm: [
    transport:
      {:streamable_http,
       url: "https://mcp.crm.example/mcp",
       headers: %{"authorization" => ["Bearer ", {:secret, "CRM_KEY"}]}},
    owner: "acme"
  ],
  search: [
    transport: {:streamable_http, url: "https://search.example.com/mcp"},
    cost: fn result -> %{usd: result["_meta"]["usd"]} end
  ]
]
```

- A command gets its `env` plus `HOME`, `PATH` and a few other basics, not your app's environment.
- `{:secret, name}` is read from the `owner`'s secrets each time the server connects.
  `Wardrik.MCP.reconnect/2` connects again once a secret changes.
- `cost` is counted against budgets.
- A server that's down offers no tools. It's tried again, up to a minute apart.
- The model sees `github__search_issues`, with the server's description and JSON Schema. A
  result over `max_result_bytes` is cut, and the model is told.
- Tools carry the server's hints as annotations: `read_only`, `destructive`, `idempotent`,
  `open_world`. A tool is gated unless it's read-only. Set `gated:` to change that.
- With `credential_name:`, a server offers only `<prefix>__connect` until someone connects.

## MCP on its own

`Wardrik.MCP` gives a `WardrikCore` agent a server's tools without Wardrik:

```elixir
children = [{Wardrik.MCP, name: MyApp.MCP, servers: [linear: [transport: {:streamable_http, url: "https://mcp.linear.app/mcp"}]]}]

WardrikCore.start_agent(
  agent_id: "triage",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{Wardrik.MCP, name: MyApp.MCP, servers: [:linear]}]
)
```

- Give it a `:store` so every node sees servers you `add/3` later. Their options must be data.
- Give it a `:check` to vet each URL when users supply them. Commands are then refused.
