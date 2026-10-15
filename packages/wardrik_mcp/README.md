# wardrik_mcp

The tools of any MCP server, for [Wardrik](../wardrik) agents to call.

```elixir
def deps do
  [{:wardrik_mcp, "~> 0.1.0"}]
end
```

Start `WardrikMCP.Supervisor` in your application with the servers it
reaches, and give an agent a server the way you give it any other tool:

```elixir
# lib/my_app/application.ex
children = [
  Wardrik,
  {WardrikMCP.Supervisor,
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
   ]}
]
```

```elixir
github = Wardrik.Servers.Key.deployment("github")

Wardrik.LLM.Config.new(tools: [{WardrikMCP, github}])    # one server
Wardrik.LLM.Config.new(tools: [{WardrikMCP, :*}])        # every server connected
```

A server is named by its `Wardrik.Servers.Key`: whose it is, and its name.
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
{WardrikMCP.Supervisor,
 servers: [github: [transport: {:streamable_http, base_url: "..."}, credential: "github"]]}
```

The credential is resolved through the agent's `:credentials` seam, such as
[wardrik_vault](../wardrik_vault). Until a user has connected, the server
offers only `github__connect`, which asks them to authorize; see
[wardrik_oauth](../wardrik_oauth).

`WardrikMCP.Server` lists every option a server takes.

## Servers owners add

An org or a person adds a server of their own as the deployment runs,
through the `Wardrik.Servers` operations every surface offers: over HTTP,
`POST /v1/servers`. `WardrikMCP.Servers` keeps each in the store, and serves
it to its owner's agents alone:

```elixir
host = Wardrik.Host.new(store: store, servers: %WardrikMCP.Servers{store: store})

children = [
  {Wardrik, host: host},
  {WardrikMCP.Supervisor, store: store}
]
```

Such a server is reached over Streamable HTTP at an `https` URL whose host
has public addresses, signs in with nothing or with a secret its owner keeps
in the vault, and is named by its `Wardrik.Servers.Key`. Each node starts its
connection the first time an agent's tools are built with it, and stops it
after a quarter of an hour with no call; `WardrikMCP.Remote` says what an
owner can set, and what they cannot.

