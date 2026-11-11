# MCP servers

> See it in action: [Configure agent tools](../notebooks/tools-demo.livemd)

Agents call MCP servers' tools. Your resolver selects the servers available to each agent.

## Setup

Nothing here calls a model. Adding a server reaches it over the network.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.9"}])

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
- See `WardrikMCP.Server` for every server option.

## Servers your app adds

Add a server while Wardrik runs, then configure access through your resolver:

```elixir
:ok =
  WardrikMCP.add(Wardrik.mcp(MyApp.AgentRuntime), "acme:linear",
    transport: {:streamable_http, url: "https://mcp.linear.app/mcp"},
    prefix: "linear"
  )
```

- Every node reaches it, from the store.
- Agents see it from their next turn.
- The URL must be `https` at a public address. Wardrik's `:egress` option changes that.
- A server's answers come from outside. Hold its tools to a [policy](policies.md).
