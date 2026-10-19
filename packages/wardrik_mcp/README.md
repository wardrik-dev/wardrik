# wardrik_mcp

The tools of any MCP server, for [Wardrik](../wardrik) agents to call.

```elixir
def deps do
  [{:wardrik_mcp, "~> 0.1.0"}]
end
```

Attach it to your Wardrik with the servers it reaches, and a definition names
each server's tools as `github/*`:

```elixir
# lib/my_app/agents.ex
wardrik =
  Wardrik.new(store: store)
  |> WardrikMCP.attach(
    servers: [
      github: [
        transport:
          {:stdio,
           command: "github-mcp-server",
           env: %{"GITHUB_TOKEN" => System.get_env("GITHUB_TOKEN")}},
        only: ~w(search_issues create_issue)
      ],
      linear: [
        transport:
          {:streamable_http,
           base_url: "https://mcp.linear.app/mcp",
           headers: %{"authorization" => "Bearer " <> System.fetch_env!("LINEAR_TOKEN")}}
      ]
    ]
  )

children = [{WardrikStore, store}, {Wardrik, wardrik}]
```

`{Wardrik, wardrik}` starts `WardrikMCP.Supervisor`, which connects to them. A
config names a server by its resource, as a tool:

```elixir
github = Wardrik.Resource.parse!("deployment/server/github")

Wardrik.LLM.Config.new(tools: [{WardrikMCP, github}])    # one server
Wardrik.LLM.Config.new(tools: [{WardrikMCP, :*}])        # every server connected
```

A server is named by its `Wardrik.Resource`: whose it is, and its name.
The servers the supervisor starts are the deployment's own. `{WardrikMCP,
github}` stands for however many tools that server offers, and
they arrive as `github__search_issues`, with the server's own JSON Schema. Each
server connects on its own, so one that is down offers no tools and holds up
nothing else.

A tool call that is stopped is cancelled on the server too, and a server's
progress reaches the turn's events as a `Wardrik.Event.ToolProgress`.

## Per-user servers

A server that acts as a user names the credential each call is made with, and
runs over a connection of that user's own:

```elixir
WardrikMCP.attach(host,
  servers: [github: [transport: {:streamable_http, base_url: "..."}, credential: "github"]]
)
```

The credential is resolved through the agent's `:credentials` seam, such as
[the vault](../wardrik/guides/vault.md). Until a user has connected, the server
offers only `github__connect`, which asks them to authorize; see
[wardrik_oauth](../wardrik_oauth).

`WardrikMCP.Server` lists every option a server takes.

## Servers owners add

An org or a person adds a server of their own as the deployment runs,
through `Wardrik.servers_add/3`, which every surface offers: over HTTP,
`POST /v1/servers`. `WardrikMCP.Servers` keeps each in the store, and serves
it to its owner's agents alone, which name it as `books/*`, or every one
their owner adds as `servers/*`:

```elixir
oauth = WardrikOAuth.new(added: %WardrikMCP.Servers.Providers{store: store})
vault = WardrikVault.new(store: store, keys: keys, grants: oauth)
servers = %WardrikMCP.Servers{store: store, oauth: oauth, vault: vault}

wardrik =
  Wardrik.new(store: store, credentials: vault, servers: servers)
  |> WardrikMCP.attach()
```

Such a server is reached over Streamable HTTP at an `https` URL whose host
has public addresses, signs in with nothing, in a browser, or with a secret
its owner keeps in the vault, and is named by its `Wardrik.Resource`. A
server signed in to is one of `WardrikOAuth`'s providers through
`WardrikMCP.Servers.Providers`, for its owner alone. Each node starts its
connection the first time an agent's tools are built with it, and stops it
after a quarter of an hour with no call; `WardrikMCP.Remote` says what an
owner can set, and what they cannot.

