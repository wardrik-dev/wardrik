# MCP servers

Agents call the tools of MCP servers. Give Wardrik the servers every agent may reach when it
starts. Orgs and people add their own while it runs.

## Servers Wardrik starts with

```elixir
config :my_app, MyApp.Wardrik,
  mcp: [
    github: [
      transport: {:streamable_http, base_url: "https://api.githubcopilot.com/mcp/"},
      credential_name: "github"
    ]
  ]
```

A definition names the server's tools as `github/*`. See `WardrikMCP.Server` for every option.

With `credential_name`, each person's agents reach the server with that person's own account.
Someone who hasn't connected one is asked to sign in the first time one of their agents calls it;
see [Credentials](credentials.md). Until anyone has, the server offers one tool, `github__connect`,
so an agent can begin.

## Servers an org or a person adds

An org or a person adds a server for their own agents while Wardrik runs. Every node reaches it:

```elixir
Wardrik.MCPServers.add(scope,
  owner: "acme",
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
```

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
| `%{secret: %{name: "crm-key"}}` | A key the owner keeps in the vault, sent as `authorization: Bearer <key>`. `header` and `scheme` change that. |
| `%{oauth: %{scopes: [...]}}` | Each person signs in as themselves, through the server's own authorization server. Wardrik registers itself as the client. |
| `%{oauth: %{issuer: ..., client_id: ..., client_secret: %{name: "CRM_APP"}}}` | The same, through an OAuth app the owner registered there, for a service Wardrik can't discover or register with. |

An owner's own OAuth app takes:

  * `issuer`, or `authorization_endpoint` and `token_endpoint` where it publishes no metadata.
  * `client_id`.
  * `client_secret`, the name of a secret the owner keeps in the vault. It's sealed apart from the
    owner's secrets when the server is added, so no agent can name it. It's sent only to the token
    endpoint: in the form, or as HTTP Basic with `client_auth: "basic"`.

Each owner's server signs in on its own. Two orgs' servers of the same name each use their own app.

### Listing and removing

`Wardrik.MCPServers.list/2` lists an owner's servers. `Wardrik.MCPServers.remove/3` removes one and
forgets the sign-ins to it. Each change is recorded in the audit.

A server's answers are written by others. Hold its tools to a [policy](policies.md).
