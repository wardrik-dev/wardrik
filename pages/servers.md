# MCP servers

Agents call the tools of MCP servers. Give Wardrik the servers every agent may reach as it starts,
and let each org and person add their own as it runs.

## Servers Wardrik starts with

```elixir
Wardrik.new(
  name: MyApp.Wardrik,
  data_dir: "/var/lib/my_app",
  mcp: [
    github: [
      transport: {:streamable_http, base_url: "https://api.githubcopilot.com/mcp/"},
      credential_name: "github"
    ]
  ]
)
```

A definition names a server's tools as `github/*`. With `credential_name`, each person's agents reach
it with their own account, and someone who hasn't connected one is asked to sign in the first time
an agent of theirs calls it; see [Credentials](credentials.md). Until anyone has, the server offers
one tool, `github__connect`, so an agent can begin.

## Servers an org or a person adds

An org or a person adds a server for their own agents while Wardrik runs, and every node reaches
it:

```elixir
{:ok, %Wardrik.MCPServerAdded{connected: false, authorization: %Wardrik.Authorization{url: url}}} =
  Wardrik.MCPServers.add(scope,
    owner: "acme",
    name: "linear",
    url: "https://mcp.linear.app/mcp",
    auth: %{oauth: %{}}
  )
```

- **An org's server** serves its own agents and every agent of its people. **A person's** serves
  their agents alone, and comes first where both have one of the same name.
- **`linear/*`** names the agent's owner's server first, then its org's, then one Wardrik started
  with. **`servers/*`** gives every server its owner adds, as they add them. A server added or
  removed reaches the agent from its next turn, without defining it again.
- **A server not added yet** offers nothing, and the definition lists it as `missing`.

How the agents sign in to it:

| `auth` | Means |
| --- | --- |
| `%{none: %{}}` | it takes no credential |
| `%{secret: %{name: "crm-key"}}` | a key the owner keeps in the vault, sent as `authorization: Bearer <key>`; `header` and `scheme` change that |
| `%{oauth: %{scopes: [...]}}` | each person signs in as themselves, through the server's own authorization server; Wardrik registers itself there |

`only` and `except` narrow the tools it offers. `Wardrik.MCPServers.list/2` and
`Wardrik.MCPServers.remove/3` list and remove an owner's servers, and removing one forgets the
sign-ins to it. Each change is recorded in the audit.

Notice a server's answers are written by others. Hold its tools to a [policy](policies.md).
