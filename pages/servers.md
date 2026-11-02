# MCP servers

Agents call the tools of MCP servers. Give Wardrik the servers every agent may reach when it
starts. Your app adds more while it runs.

> See it in action: [Give agents tools](../notebooks/tools-demo.livemd)

## Setup

In a fresh IEx session, start Wardrik with GitHub's MCP server, and an OAuth app people sign in to
it with:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.2"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer

  @impl true
  def authorize(_request, _opts), do: :ok
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    keys: [WardrikVault.generate_key()],
    oauth: [
      page: "https://agents.example.com/oauth",
      providers: [
        github: [
          authorization_endpoint: "https://github.com/login/oauth/authorize",
          token_endpoint: "https://github.com/login/oauth/access_token",
          client_id: "Iv1.your-client-id",
          client_secret: "your-client-secret"
        ]
      ]
    ],
    mcp: [
      github: [
        transport: {:streamable_http, url: "https://api.githubcopilot.com/mcp/"},
        credential_name: "github"
      ]
    ]
  )

scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria")
```

The client ID and secret stand for your GitHub OAuth app's. Nothing on this page calls a model.
Adding a server reaches it over the network.

## Servers Wardrik starts with

`:mcp` names the servers every agent may reach. A definition names a server's tools as `github/*`:

```elixir
{:ok, _agent} =
  Wardrik.Agent.define(scope, "acme/@maria/assistant",
    model: "anthropic:claude-haiku-4-5",
    tools: ["github/*", "linear/*"]
  )

Wardrik.Agent.definition(scope, "acme/@maria/assistant")
#=> {:ok, %Wardrik.Definition{tools: ["github/*", "linear/*"], ...}, ["linear/*"]}
```

The last element lists what the definition names that isn't there yet. `linear` is added below.
See `WardrikMCP.Server` for every option of a server.

With `credential_name`, each person's agents reach the server with that person's own account.
Someone who hasn't connected one is asked to sign in the first time one of their agents calls it;
see [Credentials](credentials.md). Until anyone has, the server offers one tool, `github__connect`,
so an agent can begin.

## Servers your app adds

Your app adds a server while Wardrik runs with `WardrikMCP.add/3`, and gives it to the agents that
reach it through its resolver:

```elixir
:ok =
  WardrikMCP.add(Wardrik.mcp(MyApp.AgentRuntime), "acme:linear",
    transport: {:streamable_http, url: "https://mcp.linear.app/mcp"},
    prefix: "linear",
    owner: "acme"
  )

# In your resolver: acme's agents reach it as linear/*.
%Wardrik.Resolved{servers: %{"linear" => "acme:linear"}}
```

  * Every node reaches it, from the store.
  * A server added or removed reaches the agent from its next turn, without defining it again.
  * A server not added yet offers nothing, and the definition lists it as missing.
  * `servers/*` gives every server the agent is resolved with.
  * `wardrik_daemon` adds servers for orgs and people this way.

The URL must be `https`, at a public address. Wardrik checks it when the server is added and when
each connection starts. Wardrik's `:egress` option changes what may be reached. Use
`&Wardrik.Egress.any/1` when only the operator adds servers.

A server's answers are written by others. Hold its tools to a [policy](policies.md).
