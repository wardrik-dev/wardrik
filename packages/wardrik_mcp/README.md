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
Wardrik.LLM.Config.new(tools: [{WardrikMCP, :github}])   # one server
Wardrik.LLM.Config.new(tools: [{WardrikMCP, :*}])        # every server connected
```

`{WardrikMCP, :github}` stands for however many tools that server offers, and
they arrive as `github__search_issues`, with the server's own JSON Schema. Each
server connects on its own, so one that is down offers no tools and holds up
nothing else.

A tool call that is stopped is cancelled on the server too, and a server's
progress reaches the turn's events as `{:tool_progress, call_id, name,
progress, total}`.

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
