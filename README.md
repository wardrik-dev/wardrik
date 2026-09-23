# Tars

An agent runtime built on OTP. Agents are processes, delegation is a function
call, and everything one agent does publishes to one event stream you can
subscribe to and watch.

Core has no dependencies you did not ask for and ships no tools and no
workflows. What it ships is the contracts and the machinery that runs them.

## Terminal client

Run `mix tars` for the terminal client; `mix help tars` lists its options.

## Packages

Anything that reaches the outside world, or that encodes work specific to one
deployment, lives in a package rather than in core. A package is named for its
subject and never defines modules under `Tars.`:

```elixir
Tars.LLM.Config.new(tools: [TarsBrave.WebSearch, TarsResearch.Deep])
```

| | |
| --- | --- |
| **`Tars.*`** | core |
| **`Tars<Subject>`** | a package, for example `TarsBrave`, `TarsResearch` |

There is one list, `:tools`, because a workflow reaches an agent by being
callable, which makes it a tool. A workflow the agent cannot call is a
function the deployment calls itself and does not need registering.

### Naming

**The module is qualified by its package; the tool name is not.** A module only
has to say what distinguishes it inside its package, since the package name is
right there. A tool name is a bare string in a flat namespace the model sees,
so it carries everything.

```
TarsBrave.WebSearch      tool "web_search"       "brave" is ours, not the model's
TarsResearch.Deep        tool "deep_research"    "research" is the model's, so the tool re-adds it
```

Tool names are flat per config, so two packages shipping the same tool name
collide. Pick a specific one.

### Writing one

A tool implements `Tars.Tool`:

```elixir
defmodule MyPack.Ping do
  @behaviour Tars.Tool

  @impl true
  def tool do
    ReqLLM.Tool.new!(
      name: "ping",
      description: "Check whether a host answers.",
      parameter_schema: [host: [type: :string, required: true, doc: "Host to reach"]],
      callback: {__MODULE__, :run}
    )
  end

  def run(%{host: host}), do: Tars.Tool.Result.ok(%{"reachable" => reachable?(host)})
end
```

A workflow implements `Tars.Workflow.Step`, and implements `Tars.Tool` as well
if an agent should be able to call it:

```elixir
defmodule MyPack.Nightly do
  @behaviour Tars.Tool
  @behaviour Tars.Workflow.Step

  @impl Tars.Tool
  def tool do
    Tars.Workflow.as_tool(__MODULE__,
      name: "nightly",
      description: "Summarise everything that changed since a date.",
      parameter_schema: [since: [type: :string, required: true, doc: "ISO date"]]
    )
  end

  @impl Tars.Workflow.Step
  def run(%{since: since}, scope, _opts) do
    scope
    |> Tars.Workflow.fan_out(repos(), fn repo, branch ->
      Tars.Subagent.run(branch, "What changed in #{repo} since #{since}?", except_tools: ["nightly"])
    end)
    |> report()
  end
end
```

`as_tool/2` is an ordinary function, so a workflow whose name and schema are
only known at runtime is built the same way. `Tars.Subagent.run/3` takes
`:name`, `:system`, `:tools`, `:except_tools`, `:model` and `:config`, so a
workflow never has to reach into a `Tars.Scope` or a `Tars.LLM.Config` to
decide who the work it delegates is, or what it can do.

A persona is `:system` on the config, prepended to every turn rather than
stored in the conversation, so changing it changes the agent and a subagent's
persona never leaks into the caller's history.

Prefer an MFA callback over an anonymous function for anything a config holds,
so it survives being named by a config that crosses a node boundary.

### Sandboxes

Code an agent writes runs in a `Tars.Sandbox`. Core ships the contract and no
sandbox. `TarsLua` implements it over a Lua 5.3 VM written in Elixir, and
hands an agent the `run_lua` tool:

```elixir
Tars.LLM.Config.new(tools: [TarsLua.Run])
```

The VM reaches nothing outside itself — no files, no network, no environment,
and nothing else the agent has. A sandbox implements a language and nothing
else: `Tars.Sandbox.run/3` checks the code, then evaluates it in a task of its
own under `Tars.Sandbox.Limits` — a deadline, a memory budget, a step budget
and a call depth, each of which can be lifted with `:infinity`.

```elixir
TarsLua.Run.tool(limits: Tars.Sandbox.Limits.new(timeout_ms: :timer.seconds(5)))
```

### MCP servers

An MCP server's tools are named in a config the way any other tool is, through
`TarsMCP` as a *source*: one spec standing for however many tools that server
offers.

```elixir
config :tars, TarsMCP,
  servers: [
    github: [
      transport:
        {:stdio,
         command: "github-mcp-server",
         env: %{"GITHUB_TOKEN" => System.get_env("GITHUB_TOKEN")}},
      only: ~w(search_issues create_issue)
    ]
  ]

Tars.LLM.Config.new(tools: [{TarsMCP, :github}])
```

The host starts `TarsMCP.Supervisor`; `mix tars --mcp github` does it for the
TUI. Connections keep to themselves, so a server that is down offers no tools
and stops nothing else. Tools arrive as `github__search_issues`, carrying the
server's own JSON Schema.

A stopped tool call is cancelled on the server too: the connection watches
whoever is calling, and tells the server to drop the request when that caller
dies of anything but its own success. A server's progress notifications reach
the turn's event stream as `{:tool_progress, call_id, name, progress, total}`,
under the span of the call they belong to.

### Credentials, and authorizing a user

A tool names the secret it needs rather than holding one, and the scope
resolves it:

```elixir
case Tars.Credential.resolve(scope, {:user, "github"}) do
  {:ok, credential} -> call(Tars.Credential.reveal(credential))
  {:error, {:authorization_required, url}} -> {:park, "Connect GitHub: " <> url}
end
```

`:credentials` is a scope seam beside `:policy` and `:dispatch`. Two resolvers
ship with the binary. `TarsVault` seals secrets with AES-256-GCM into
`Tars.Store`, the store the fleet already runs on — no broker, and no plaintext
fallback without a key:

```elixir
config :tars, TarsVault, keys: [System.fetch_env!("TARS_VAULT_KEY")]

TarsVault.put({:user, "github"}, "jon", "ghp_xxx")
```

`TarsOAuth` gets them by asking the user instead. It discovers the
authorization server from the resource, presents whichever client identity the
server will accept — one registered by hand, its own metadata document, or a
dynamic registration — and runs authorization code with PKCE. A user who has
not authorized yet parks the turn on a link; following it and answering `y`
runs the call again with the token, which is then sealed by `TarsVault` and
refreshed without asking again.

```elixir
config :tars, TarsOAuth,
  client: [name: "Tars", document_url: "https://tars.dev/oauth/client"],
  providers: [
    github: [
      resource: "https://api.githubcopilot.com/mcp/",
      client_id: System.get_env("GITHUB_CLIENT_ID"),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
      scopes: ~w(repo)
    ]
  ]
```

An MCP server reached as the user names the reference to resolve, and each user
gets a connection of their own:

```elixir
config :tars, TarsMCP,
  servers: [github: [transport: {:streamable_http, base_url: "..."}, credential: {:user, "github"}]]
```

A credential fixed for the whole deployment is part of the transport — `:env`
for a command, `:headers` for HTTP:

```elixir
transport: {:streamable_http,
  base_url: "https://mcp.example.com/mcp",
  headers: %{"authorization" => "Bearer " <> token}}
```

### Living in this repo

Packages start here, under `lib/<package>/` with tests mirrored at
`test/<package>/`, and move out when there is a reason to. While a package is
in-repo its settings nest under the application that exists:

```elixir
config :tars, TarsBrave, api_key: System.fetch_env!("BRAVE_API_KEY")
```

After extraction that becomes `config :tars_brave, api_key: ...`. Each package
documents its own extraction in its moduledoc. Nothing in `Tars` changes
either way, because core names no tool and no workflow.

## Seams

Core runs agents. Everything that decides *who* an agent is working for, *what*
it may do, and *who pays for it* is a seam a host reaches through, so a
deployment that needs none of them configures none of them.

```elixir
key = Tars.Fleet.key("assistant", user: current_user, org: current_org)

Tars.Fleet.spawn(key,
  config: config,
  policy: MyApp.Policy,      # may this tool call run?
  dispatch: MyApp.Gateway,   # which model, whose key, what did it cost?
  timeout: :timer.minutes(10)
)
```

| | |
| --- | --- |
| **`:user`, `:org`** | written into the agent's key through `Tars.Fleet.Segment` and carried on `Tars.Scope`, the way a Phoenix scope carries them. Your own values; core never reads inside them and never puts them in an event. |
| **`:policy`** | a `Tars.Policy`. Asked about every tool call before it runs, and answers `:allow`, `{:deny, reason}` or `{:ask, prompt}`. |
| **`:dispatch`** | a `Tars.LLM.Dispatch`. `admit/2` decides what the call actually is, immediately before it is made; `settle/3` reports what it cost. |
| **`:timeout`** | a deadline on the scope. Work can narrow it and never widen it. |

A policy that asks **parks** the turn: nothing runs, nothing is appended to the
conversation, and the agent waits.

```elixir
Tars.Agent.parked(:assistant)
#=> [{%{id: "call_1", name: "deploy", arguments: %{}}, "This ships to production."}]

Tars.Agent.resume(:assistant, %{"call_1" => :approve})
```

Approval, a credential that needs connecting, and a call a person has to run
elsewhere are all the same shape, so there is one mechanism rather than three.

### Stopping things

```elixir
Tars.Agent.interrupt(:assistant)                      # the whole turn
Tars.LLM.ToolRunner.kill_call(:assistant, "call_1")   # one tool call
Tars.LLM.ToolRunner.in_flight(:assistant)             # what could be stopped
```

A killed call is answered with an error result, so the model is never left with
a call nobody answered.

### Failures

`Tars.Failure.classify/1` sorts a turn's error into `:transient`, `:ceiling` or
`:bug`, so a caller knows whether trying again is worth anything. Anything
unrecognised is a `:bug` — a retry loop that assumes otherwise spends real
money finding out.

## Installation

```elixir
def deps do
  [
    {:tars, "~> 0.1.0"}
  ]
end
```

## Running the daemon

`mix release` builds the daemon: a self-contained node with its own ERTS, and
a tarball of it. CI builds one for Linux x86_64 on every push to `main` and
attaches it to the GitHub release for a `v*` tag.

```sh
MIX_ENV=prod mix release
_build/prod/rel/tarsd/bin/tars start     # in the background
_build/prod/rel/tarsd/bin/tars status    # what it is running
_build/prod/rel/tarsd/bin/tars remote    # an IEx shell on it
_build/prod/rel/tarsd/bin/tars logs      # follow its log
_build/prod/rel/tarsd/bin/tars stop
```

`tars serve` runs it in the foreground, logging to the terminal, for a
service manager to supervise. `bin/tarsd` is the node's own release script
underneath.

The daemon follows the XDG base directories, so `~/.config/tars` holds only
what a person writes and can live in a dotfiles repository:

| | |
| --- | --- |
| **`~/.config/tars/config.toml`** | MCP servers, OAuth providers and vault keys. See `TarsDaemon.Config` |
| **`~/.local/share/tars/store/`** | the store |
| **`~/.local/share/tars/cookie`** | the node's cookie, created on first boot and readable by its owner only |
| **`~/.local/state/tars/log/`** | `tars.log`, and `mcp.log` for what MCP commands write to stderr |

`XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME` move them, as they
move any other tool's.

```toml
[mcp.linear]
url = "https://mcp.linear.app/mcp"
headers = { authorization = "Bearer ${LINEAR_TOKEN}" }
```

`${NAME}` is read from the environment when the daemon boots, and so are
provider keys such as `ZAI_API_KEY`. A key that is absent is reported by the
tool that needs it; a `config.toml` that does not read stops the boot.

An MCP command sees only a few of the daemon's environment variables
(`HOME`, `PATH`, `USER` and the like) beside the ones its server sets, so the
cookie and every key the daemon holds stay with the daemon.
`TarsMCP.Server`'s `:inherit_env` names others.

The daemon is `TarsDaemon`, started as one of core's `:children`. A host of
its own adds to the tree the same way:

```elixir
config :tars, :children, [MyApp.Host]
```

| | |
| --- | --- |
| **`TARS_CONFIG_DIR`**, **`TARS_STATE_DIR`** | the config and state directories, when not the XDG ones |
| **`TARS_DATA_DIR`**, **`TARS_COOKIE_FILE`** | the store and the cookie. `RELEASE_COOKIE` overrides the cookie file |
| **`TARS_DIST_INTERFACE`** | the address distribution listens on, as an Erlang tuple. Defaults to loopback, where the node is `tarsd@localhost`; `any` listens everywhere |
| **`TARS_LOG`** | the log file, or `-` for the terminal |
| **`TARS_CLUSTER_SIZE`** | the store's voting members |

Anyone who can reach the distribution port with the cookie can run code on the
node. Listen beyond loopback only on a network you trust.

## License

Apache-2.0. See [LICENSE](LICENSE).
