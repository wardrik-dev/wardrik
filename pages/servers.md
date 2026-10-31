# MCP servers

Agents call the tools of MCP servers. Give Wardrik the servers every agent may reach when it
starts. Orgs and people add their own while it runs.

> See it in action: [Give agents tools](../notebooks/tools-demo.livemd)

## Setup

In a fresh IEx session, start Wardrik with GitHub's MCP server, and an OAuth app people sign in to
it with:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.1"}])

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
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

scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria", roles: [:owner], resources: ["acme/@maria/*"])
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

## Servers an org or a person adds

An org or a person adds a server for their own agents while Wardrik runs. Every node reaches it:

```elixir
Wardrik.MCPServers.add(scope,
  owner: "acme/@maria",
  name: "linear",
  url: "https://mcp.linear.app/mcp",
  auth: %{oauth: %{}}
)
#=> {:ok,
#=>  %Wardrik.MCPServerAdded{
#=>    server: "linear",
#=>    connected: false,
#=>    authorization: %Wardrik.Authorization{url: "https://mcp.linear.app/authorize?...", code: nil}
#=>  }}

Wardrik.Agent.definition(scope, "acme/@maria/assistant")
#=> {:ok, %Wardrik.Definition{...}, []}
```

Open the URL to sign in.

  * An org's server serves the org's agents and every agent of its people. A person's server
    serves their agents alone, and wins where both have one of the same name.
  * `linear/*` names the agent owner's server first, then its org's, then one Wardrik started
    with.
  * `servers/*` gives every server the owner adds, as they add them.
  * A server added or removed reaches the agent from its next turn, without defining it again.
  * A server not added yet offers nothing, and the definition lists it as missing.
  * `only` and `except` narrow the tools it offers, by the server's own tool names.

### Where it may be

The URL must be `https`, at a public address. Wardrik checks it when the server is added and when
each connection starts. It checks the authorization server it names, and the endpoints that lists,
as each sign-in reaches them.

Wardrik's `:egress` option changes what may be reached. Use `&Wardrik.Egress.any/1` when only the
operator adds servers.

### How agents sign in to it

| `auth` | Means |
| --- | --- |
| `%{none: %{}}` | It takes no credential. |
| `%{secret: %{name: "crm-key"}}` | A key the owner keeps in the vault, sent as `authorization: Bearer <key>`. `header` and `scheme` change that. It's read as each connection starts, so a new value takes effect at once. |
| `%{oauth: %{scopes: [...]}}` | Each person signs in as themselves, through the server's own authorization server. Wardrik registers itself as the client. Needs Wardrik's `:oauth`. |
| `%{oauth: %{provider: "google"}}` | The same, through an OAuth app the owner can use: their own, their org's or the deployment's. See [Credentials](credentials.md). |
| `%{oauth: %{issuer: ..., client_id: ..., client_secret: %{name: "CRM_APP"}}}` | The same, through an OAuth app the owner registered there, for a service Wardrik can't discover or register with. |

The owner keeps a key with `Wardrik.put_secret/5`; see [Credentials](credentials.md).

An owner's own OAuth app takes:

  * `issuer`, or `authorization_endpoint` and `token_endpoint` where it publishes no metadata.
  * `client_id`.
  * `client_secret`, the name of a secret the owner keeps in the vault. It's read each time it's
    needed, so a new value takes effect at once. It's sent only to the token endpoint: in the
    form, or as HTTP Basic with `client_auth: "basic"`.
  * `authorization_params`, extra parameters for the sign-in, as `%{access_type: "offline"}`.

Each owner's server signs in on its own. Two orgs' servers of the same name each use their own app.

A server that names an app signs in as the app: its account is the app's, so connecting the app
once covers every server that names it.

### Listing and removing

```elixir
Wardrik.MCPServers.list(scope, owner: "acme/@maria")
#=> {:ok,
#=>  [
#=>    %Wardrik.MCPServer{owner: "acme/@maria", name: "linear", source: :runtime, auth: :oauth, ...},
#=>    %Wardrik.MCPServer{owner: "deployment", name: "github", source: :config, auth: :oauth, ...}
#=>  ]}

Wardrik.MCPServers.remove(scope, "linear", owner: "acme/@maria")
#=> {:ok, %Wardrik.MCPServer{owner: "acme/@maria", name: "linear", source: :runtime, ...}}
```

The list holds the servers the owner's agents reach, the nearest of each name: their own, their
org's, the deployment's, then those Wardrik started with. `source` is `:config` for those, which
are listed without their headers.

An owner removes their own servers alone. Removing one forgets the sign-ins to it, unless it names
an app. Each change is recorded in the audit.

A server's answers are written by others. Hold its tools to a [policy](policies.md).
