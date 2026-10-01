# Wardrik

An agent runtime built on OTP. Agents are processes, delegation is a function
call, and everything one agent does publishes to one event stream you can
subscribe to and watch.

Core has no dependencies you did not ask for and ships no tools and no
workflows. What it ships is the contracts and the machinery that runs them.

## Run it

On Linux, the daemon and the `wardrik` command:

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | sh
wardrik service install                       # runs it under your systemd, from boot
wardrik token create dev --all --unlimited    # a token for the HTTP API on 127.0.0.1:4747
```

`wardrik start` runs it in the background instead, until you stop it, and
`wardrik doctor` checks what it reads before it does.

Anywhere Docker runs:

```sh
docker run -d --name wardrik -p 127.0.0.1:4747:4747 -v wardrik:/data ghcr.io/wardrik-dev/wardrik
docker exec wardrik wardrik token create dev --all --unlimited
```

The script installs the release for Linux on x86_64 or arm64, which needs glibc 2.35
and OpenSSL 3, as Ubuntu 22.04 and Debian 12 and everything since have. It
checks the tarball against the release's `SHA256SUMS`, runs it once, and
installs it under `~/.local`, or `/opt/wardrik` as root; `deploy/install.sh`
says what else it takes. `rik` is `wardrik` too, unless something else on the
machine is already called `rik`. Elsewhere, the image runs. See
[Running the daemon](#running-the-daemon), or [Installation](#installation)
to use Wardrik as a library.

## Terminal client

Run `mix wardrik` for the terminal client; `mix help wardrik` lists its options.

## Packages

Anything that reaches the outside world, or that encodes work specific to one
deployment, lives in a package rather than in core. A package is named for its
subject and never defines modules under `Wardrik.`:

```elixir
Wardrik.LLM.Config.new(tools: [WardrikBrave.WebSearch, WardrikResearch.Deep])
```

| | |
| --- | --- |
| **`Wardrik.*`** | core |
| **`Wardrik<Subject>`** | a package, for example `WardrikBrave`, `WardrikResearch` |

There is one list, `:tools`, because a workflow reaches an agent by being
callable, which makes it a tool. A workflow the agent cannot call is a
function the deployment calls itself and does not need registering.

### Naming

**The module is qualified by its package; the tool name is not.** A module only
has to say what distinguishes it inside its package, since the package name is
right there. A tool name is a bare string in a flat namespace the model sees,
so it carries everything.

```
WardrikBrave.WebSearch      tool "web_search"       "brave" is ours, not the model's
WardrikResearch.Deep        tool "deep_research"    "research" is the model's, so the tool re-adds it
```

Tool names are flat per config, so two packages shipping the same tool name
collide. Pick a specific one.

### Writing one

A tool implements `Wardrik.Tool`:

```elixir
defmodule MyPack.Ping do
  @behaviour Wardrik.Tool

  @impl true
  def tool do
    ReqLLM.Tool.new!(
      name: "ping",
      description: "Check whether a host answers.",
      parameter_schema: [host: [type: :string, required: true, doc: "Host to reach"]],
      callback: {__MODULE__, :run}
    )
  end

  def run(%{host: host}), do: Wardrik.Tool.Result.ok(%{"reachable" => reachable?(host)})
end
```

A workflow implements `Wardrik.Workflow.Step`, and implements `Wardrik.Tool` as well
if an agent should be able to call it:

```elixir
defmodule MyPack.Nightly do
  @behaviour Wardrik.Tool
  @behaviour Wardrik.Workflow.Step

  @impl Wardrik.Tool
  def tool do
    Wardrik.Workflow.as_tool(__MODULE__,
      name: "nightly",
      description: "Summarise everything that changed since a date.",
      parameter_schema: [since: [type: :string, required: true, doc: "ISO date"]]
    )
  end

  @impl Wardrik.Workflow.Step
  def run(%{since: since}, scope, _opts) do
    scope
    |> Wardrik.Workflow.fan_out(repos(), fn repo, branch ->
      Wardrik.Subagent.run(branch, "What changed in #{repo} since #{since}?", except_tools: ["nightly"])
    end)
    |> report()
  end
end
```

`as_tool/2` is an ordinary function, so a workflow whose name and schema are
only known at runtime is built the same way. `Wardrik.Subagent.run/3` takes
`:name`, `:system`, `:tools`, `:except_tools`, `:model` and `:config`, so a
workflow never has to reach into a `Wardrik.Scope` or a `Wardrik.LLM.Config` to
decide who the work it delegates is, or what it can do.

A persona is `:system` on the config, prepended to every turn rather than
stored in the conversation, so changing it changes the agent and a subagent's
persona never leaks into the caller's history.

Prefer an MFA callback over an anonymous function for anything a config holds,
so it survives being named by a config that crosses a node boundary.

### Sandboxes

Code an agent writes runs in a `Wardrik.Sandbox`. Core ships the contract and no
sandbox. `WardrikLua` implements it over a Lua 5.3 VM written in Elixir, and
hands an agent the `run_lua` tool:

```elixir
Wardrik.LLM.Config.new(tools: [WardrikLua.Run])
```

The VM reaches nothing outside itself — no files, no network, no environment,
and nothing else the agent has. A sandbox implements a language and nothing
else: `Wardrik.Sandbox.run/3` checks the code, then evaluates it in a task of its
own under `Wardrik.Sandbox.Limits` — a deadline, a memory budget, a step budget
and a call depth, each of which can be lifted with `:infinity`.

```elixir
WardrikLua.Run.tool(limits: Wardrik.Sandbox.Limits.new(timeout_ms: :timer.seconds(5)))
```

### MCP servers

An MCP server's tools are named in a config the way any other tool is, through
`WardrikMCP` as a *source*: one spec standing for however many tools that server
offers.

```elixir
config :wardrik, WardrikMCP,
  servers: [
    github: [
      transport:
        {:stdio,
         command: "github-mcp-server",
         env: %{"GITHUB_TOKEN" => System.get_env("GITHUB_TOKEN")}},
      only: ~w(search_issues create_issue)
    ]
  ]

Wardrik.LLM.Config.new(tools: [{WardrikMCP, :github}])
```

The host starts `WardrikMCP.Supervisor`; `mix wardrik --mcp github` does it for the
TUI. Connections keep to themselves, so a server that is down offers no tools
and stops nothing else. Tools arrive as `github__search_issues`, carrying the
server's own JSON Schema.

A stopped tool call is cancelled on the server too: the connection watches
whoever is calling, and tells the server to drop the request when that caller
dies of anything but its own success. A server's progress notifications reach
the turn's event stream as `{:tool_progress, call_id, name, progress, total}`,
under the span of the call they belong to.

### Credentials, and authorizing a user

A tool names the secret it needs rather than holding one, and resolves it
for the `Wardrik.Call` it was handed (see `Wardrik.Tool.new!/1`):

```elixir
case Wardrik.Credential.resolve(call, "github") do
  {:ok, credential} -> Wardrik.Call.answer(call, fetch(Wardrik.Credential.reveal(credential)))
  {:error, {:authorization_required, url}} -> Wardrik.Call.park(call, "Connect GitHub: " <> url)
  {:error, {:authorization_required, url, code}} -> Wardrik.Call.park(call, "Enter #{code} at #{url}")
end
```

`:credentials` is a scope seam beside `:hooks` and `:dispatch`. `WardrikVault`
is the resolver that ships with the binary: it seals credentials with
AES-256-GCM into `Wardrik.Store`, the store the fleet already runs on — no
broker, and no plaintext fallback without a key — and finds a name for each
call the most specific first, the call's user's, then its org's, then the
deployment's:

```elixir
config :wardrik, WardrikVault, keys: [System.fetch_env!("WARDRIK_VAULT_KEY")], grants: WardrikOAuth

WardrikVault.put("github", {"acme", "jon"}, "ghp_xxx")   # jon's, in acme
WardrikVault.put("pagerduty", "acme", "pd_xxx")         # acme's
WardrikVault.put("linear", nil, "lin_xxx")              # the deployment's
```

`WardrikOAuth` is how a credential nobody holds is asked for instead: the
vault's grants module, for a name a provider is configured under. It discovers the
authorization server from the resource, and presents whichever client identity
the server will accept — one registered by hand, its own metadata document, or
a dynamic registration. A user who has not authorized yet parks the turn, and
authorizes one of two ways:

- **in a browser**, authorization code with PKCE: a link that comes back to
  the deployment's redirect URI, the daemon's own loopback by default.
- **on another device**, the device authorization grant (RFC 8628), for any
  server that offers it: a code to enter at the server's page, from a phone
  or any browser anywhere, while the daemon asks the server whether they have.
  Nothing comes back to the daemon, so one on a server with no browser and no
  open port can be authorized from Slack.

Either way the parked call runs again by itself once they have, with the
token, which is then sealed in `WardrikVault` as their grant and refreshed
without asking again. A grant acts as whoever connected it, so only their
calls find it: a user whose org connected an account is asked for their own.
A provider's `flow` is `browser`, `device`, or `auto`, the default: on another
device where the server offers it and the daemon has no browser of its own to
send the user through, and in a browser otherwise.

```elixir
config :wardrik, WardrikOAuth,
  client: [name: "Wardrik", document_url: "https://wardrik.dev/oauth/client"],
  providers: [
    github: [
      resource: "https://api.githubcopilot.com/mcp/",
      issuer: "https://github.com/login/oauth",
      client_id: System.get_env("GITHUB_CLIENT_ID"),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
      scopes: ~w(repo),
      flow: :auto
    ]
  ]
```

An MCP server names the credential each call is made with, and runs it over a
connection of its owner's own, a user's, an org's or the deployment's:

```elixir
config :wardrik, WardrikMCP,
  servers: [github: [transport: {:streamable_http, base_url: "..."}, credential: "github"]]
```

Until a user has connected, such a server offers only `github__connect`. Once
one has, its tools are kept in the store and offered on every node, and a call
from a user who has not connected parks on the link the same way.

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
config :wardrik, WardrikBrave, api_key: System.fetch_env!("BRAVE_API_KEY")
```

After extraction that becomes `config :wardrik_brave, api_key: ...`. Each package
documents its own extraction in its moduledoc. Nothing in `Wardrik` changes
either way, because core names no tool and no workflow.

### The docs site

`docs/` is the docs site, built with Starlight. Its reference pages, the CLI,
`config.yaml`, agent files, policies, the HTTP API and events, are written from
the code by `mix wardrik.docs`, and precommit fails where they are stale:
edit the moduledoc or schema they come from. `cd docs && npm run dev` serves
it locally.

## Seams

Core runs agents. Everything that decides *who* an agent is working for, *what*
it may do, and *who pays for it* is a seam a host reaches through, so a
deployment that needs none of them configures none of them.

```elixir
key = Wardrik.Fleet.key("assistant", user: current_user, org: current_org)

Wardrik.Fleet.spawn(key,
  config: config,
  hooks: hooks,              # may this call run?
  dispatch: MyApp.Gateway,   # which model, whose key, what did it cost?
  timeout: :timer.minutes(10)
)
```

The same agent written down is a `Wardrik.Agent.Spec`, which holds no process
and no function. `Wardrik.Fleet.put/1` starts the agent a spec describes, or gives
the one already running what the spec says now:

```elixir
spec = Wardrik.Agent.Spec.new(name: "assistant", org: current_org, config: config, hooks: hooks)
{:ok, pid} = Wardrik.Fleet.put(spec)
```

| | |
| --- | --- |
| **`:org`, `:user`** | written into the agent's key through `Wardrik.Fleet.Segment`, `acme/@jon/assistant`, and carried on `Wardrik.Scope`, the way a Phoenix scope carries them. Every agent has an org: a key without one is in `config :wardrik, Wardrik.Fleet, org: ...`, and refused where none is set. The segments are in every event's `source` and every store key, so give a user's as an id, not an email address. |
| **`:hooks`** | a list of `Wardrik.Hook`s. Each is handed every tool call and model call, as a `Wardrik.Call`, before it happens, and may deny it, ask a person about it, or leave it be. The strictest answer decides. |
| **`:dispatch`** | a `Wardrik.LLM.Dispatch`. `admit/2` decides what the call actually is, immediately before it is made; `settle/3` reports what it cost. |
| **`:timeout`** | a deadline on the scope. Work can narrow it and never widen it. |

A hook is a module with `init/1` and `call/2`, the way a plug is, and a
`Wardrik.Call` is its token:

```elixir
defmodule MyApp.NoFridayDeploys do
  @behaviour Wardrik.Hook
  import Wardrik.Call

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(%Wardrik.Call{target: %Wardrik.Call.Tool{name: "deploy"}} = call, _value) do
    if friday?(), do: deny(call, "No deploys on a Friday."), else: call
  end

  def call(call, _value), do: call
end

hooks = [Wardrik.Hook.new("fridays", MyApp.NoFridayDeploys, timezone: "Europe/London")]
```

What `init/1` returns is data, so a hook travels with the agent.
`WardrikPolicy.hooks/1` gives the hooks a policy written as data is.

A hook that asks **parks** the turn: nothing runs, nothing is appended to the
conversation, and the agent waits.

```elixir
Wardrik.Agent.parked("acme/@jon/assistant")
#=> [{%{id: "call_1", name: "deploy", arguments: %{}}, "This ships to production."}]

Wardrik.Agent.resume("acme/@jon/assistant", %{"call_1" => :approve})
```

Approval, a credential that needs connecting, and a call a person has to run
elsewhere are all the same shape, so there is one mechanism rather than three.

An agent given new hooks while it waits has them decide the calls it is
waiting on: a call they allow goes ahead without a person, one they deny is
refused, and one they ask about waits on what they ask now.

### Stopping things

```elixir
Wardrik.Agent.interrupt("acme/@jon/assistant")                      # the whole turn
Wardrik.LLM.ToolRunner.kill_call("acme/@jon/assistant", "call_1")   # one tool call
Wardrik.LLM.ToolRunner.in_flight("acme/@jon/assistant")             # what could be stopped
```

A killed call is answered with an error result, so the model is never left with
a call nobody answered.

### A history that grows

An agent that runs for weeks keeps adding to one conversation. Before it
outgrows what the model can read, the agent summarises the older part with
its own model and keeps the most recent part word for word. By default it
compacts at 60% of the model's context window, as the model catalog gives it,
and keeps the last 25%:

```elixir
Wardrik.LLM.Config.new(compaction: Wardrik.Compaction.new(at: 0.5, keep: 0.2))
Wardrik.LLM.Config.new(compaction: nil)   # never
```

It happens between turns, reported as `{:context_compacted, stats}`, and the
summary is a model call like any other, so a budget counts it. An agent file
sets `compaction:` with `at`, `keep` and `window`, or `false`.

### A turn lost part way

A turn hands its agent each batch of tool calls before running any of them,
and the agent writes the batch to the store first. A turn whose node is lost
comes back replaying from that batch, with the same calls, rather than asking
the model again. With a `Wardrik.Ledger` on the scope, every call is claimed
before it runs and settled after, so the replay answers a call that already
ran with what it returned, and parks one that began and never finished for a
person to decide:

```elixir
Wardrik.Fleet.spawn(key, config: config, ledger: Wardrik.Ledger.Store)
```

A tool with an effect outside Wardrik passes `Wardrik.Ledger.idempotency_key/2` on,
so the system it calls does not repeat the effect either. The daemon gives
every agent the ledger.

### Failures

`Wardrik.Failure.classify/1` sorts a turn's error into `:transient`, `:ceiling` or
`:bug`, so a caller knows whether trying again is worth anything. Anything
unrecognised is a `:bug` — a retry loop that assumes otherwise spends real
money finding out.

## Installation

```elixir
def deps do
  [
    {:wardrik, "~> 0.1.0"},
    {:ekv, "~> 0.4.3"}
  ]
end
```

Wardrik starts with its application, keeping its store on the node's disk
through EKV. EKV is optional, as `ecto_sql` and `postgrex` are, so an
application that keeps the store elsewhere leaves it out and never compiles
its SQLite NIF. The package leaves out the TUI, which the release and the
image carry; `WardrikConsole` writes an agent's events to a terminal instead. One that keeps it in an S3 bucket names the bucket:

```elixir
# config/runtime.exs
config :wardrik, Wardrik.Store,
  adapter: WardrikS3.Store,
  bucket: "wardrik",
  endpoint: "https://<account>.r2.cloudflarestorage.com",
  region: "auto",
  access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
  secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY")
```

An application that keeps it in its own Postgres starts it after its repo,
and creates the table from a migration of its own:

```elixir
# config/config.exs
config :wardrik, start: :host
config :wardrik, Wardrik.Store, adapter: WardrikEcto.Store, repo: MyApp.Repo

# lib/my_app/application.ex
children = [MyApp.Repo, Wardrik, MyAppWeb.Endpoint]

# priv/repo/migrations/20260926000000_add_wardrik.exs
defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: WardrikEcto.Migration.up(version: 1)
  def down, do: WardrikEcto.Migration.down(version: 1)
end
```

## Running the daemon

`mix release` builds the daemon: a self-contained node with its own ERTS, and
a tarball of it. The `Dockerfile` builds both the image and the tarball the
install script installs, on Ubuntu 22.04 so the tarball runs on any Linux with
glibc 2.35. CI builds them for x86_64 and arm64 on every push, each on a
runner of that architecture, installs the tarball on fresh Ubuntu and Debian
(`dev/distros.sh`) and as a service (`dev/service.sh`), and boots the image. A
`v*` tag attaches both tarballs, their `SHA256SUMS` and `install.sh` to the
GitHub release, and names the image, for both platforms, by its version and
`latest`; a push to `main` names it `main`.

```sh
MIX_ENV=prod mix release
_build/prod/rel/wardrikd/bin/wardrik start     # in the background
_build/prod/rel/wardrikd/bin/wardrik status    # what it is running
_build/prod/rel/wardrikd/bin/wardrik ls status:parked   # the agents a query picks
_build/prod/rel/wardrikd/bin/wardrik show acme/triage # one agent in full
_build/prod/rel/wardrikd/bin/wardrik doctor    # whether config.yaml, the store, the vault, each MCP server and every agent file will do
_build/prod/rel/wardrikd/bin/wardrik reload    # read the agent and policy files again
_build/prod/rel/wardrikd/bin/wardrik ask acme/triage "What changed today?"   # and follow the answer
_build/prod/rel/wardrikd/bin/wardrik watch acme/triage   # follow what it does, until Ctrl-C
_build/prod/rel/wardrikd/bin/wardrik history acme/triage
_build/prod/rel/wardrikd/bin/wardrik parked    # what is waiting on a person
_build/prod/rel/wardrikd/bin/wardrik schedules # when each schedule runs next, and how it last ran
_build/prod/rel/wardrikd/bin/wardrik approve acme/triage call_1
_build/prod/rel/wardrikd/bin/wardrik approve   # choose among every call waiting
_build/prod/rel/wardrikd/bin/wardrik vault put LINEAR_TOKEN   # seal a secret, asking for its value
_build/prod/rel/wardrikd/bin/wardrik remote    # an IEx shell on it
_build/prod/rel/wardrikd/bin/wardrik logs      # follow its log
_build/prod/rel/wardrikd/bin/wardrik stop
```

`wardrik help` lists every command, and `wardrik help COMMAND`, or `--help`
after one, gives it in full. `status`, `ls`, `history`, `parked` and `vault ls` take `--json`,
and answer with one JSON document, the HTTP API's own where it has one. Output
is in colour where it goes to a terminal, unless `NO_COLOR` is set.
`wardrik completion bash`, `zsh` or `fish` writes a script that completes
commands, options, and the keys and parked calls of the agents running, for
`rik` as well; `wardrik help completion` says where each goes.

`ask` follows the answer as it streams, until the turn ends or waits on a
person, and `ask --no-wait` only sends the message. `watch` follows an agent
until Ctrl-C, and `watch --json` writes each event as the HTTP API streams it.
`approve` and `deny` without a call ask which, where someone is there to
answer. These run through `bin/wardrikd rpc`, so they write as they go and
read what is typed; Ctrl-C stops them, and the agent carries on.

`vault put NAME` seals a secret, such as a model provider's key, a `${NAME}`
in `config.yaml`, or the one an MCP server's `credential: NAME` reads, asking
for its value without showing it, or reading it from standard input when
piped. `--org` and `--user` seal one for an org or a user, which their agents
read before the deployment's, `vault ls` lists them by name and owner, never
their values, and `vault rm` removes one. The first `put` on a vault with no
key asks to make one, kept in `~/.local/share/wardrik/vault_key`.

`wardrik serve` runs it in the foreground, logging to the terminal, for a
service manager to supervise. `bin/wardrikd` is the node's own release script
underneath.

On Linux, `wardrik service install` makes it a service of your user's systemd:
it writes `wardrik.service` under `~/.config/systemd/user`, running `wardrik
serve` with this install's directories and anything set in
`~/.config/wardrik/env`, starts it, and lets your systemd run from boot
rather than from your first login. The unit runs the release the install
script points `current` at, so an upgrade takes effect when the service
restarts. `wardrik service uninstall` stops and removes it, and
`wardrik service unit` prints the unit without installing it. With `--node`,
each node of a cluster on the machine is an instance of `wardrik@.service`.

The daemon follows the XDG base directories, so `~/.config/wardrik` holds only
what a person writes and can live in a dotfiles repository:

| | |
| --- | --- |
| **`~/.config/wardrik/config.yaml`** | MCP servers, OAuth providers, vault keys, notify targets, the cluster and the store; `config.yml` works too. See `WardrikDaemon.Config` |
| **`~/.config/wardrik/agents/*.md`** | the agents it runs, one per file. See `WardrikDaemon.AgentFile` |
| **`~/.config/wardrik/policies/*.yaml`** | the policies agents name, as `.yaml` or `.yml`. See `WardrikPolicy` |
| **`~/.local/share/wardrik/store/`** | the store, where `config.yaml` names no other |
| **`~/.local/share/wardrik/cookie`** | the node's cookie, created on first boot and readable by its owner only |
| **`~/.local/share/wardrik/vault_key`** | the vault's key, where none is configured: the first `wardrik vault put` asks to make it. See `WardrikDaemon.VaultKey` |
| **`~/.local/state/wardrik/log/`** | `wardrik.log`, and `mcp.log` for what MCP commands write to stderr |

`XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME` move them, as they
move any other tool's.

### In Docker

The image runs `wardrik serve` as the user `wardrik`, logging to the
container's output, with `wardrik` on its `PATH` for `docker exec`:

| | |
| --- | --- |
| **`/config`** | `config.yaml`, `agents/` and `policies/`: mount yours, read-only if you like. Empty unless you do, so agents come from the HTTP API |
| **`/data`** | the store, unless `config.yaml` names one elsewhere, the cookie, the SSH host key and the vault's key. A volume, so a new container on the same volume carries on |
| **4747**, **2222** | the HTTP API, and the TUI where `/config/ssh/authorized_keys` lets someone in. Both listen on every interface of the container, so the ports it is run with decide who reaches them |

```sh
docker run -d --name wardrik \
  -p 127.0.0.1:4747:4747 -p 2222:2222 \
  -v ~/.config/wardrik:/config:ro -v wardrik:/data ghcr.io/wardrik-dev/wardrik
docker exec -it wardrik wardrik vault put ANTHROPIC_API_KEY
docker exec wardrik wardrik status
docker logs -f wardrik
```

Keys the daemon reads, a model provider's and any `config.yaml` names, are
sealed in the vault with `wardrik vault put`, its key kept on `/data`, or
come in with `-e`. An MCP server run as a command needs its program in the
image, so a deployment with one builds its own image `FROM` this one.

```yaml
mcp:
  linear:
    url: https://mcp.linear.app/mcp
    headers:
      authorization: Bearer ${LINEAR_TOKEN}
```

`${NAME}` is read from the environment when the daemon boots, or, where the
environment does not set it, from the deployment's secret of that name in the
vault, and so are provider keys such as `ZAI_API_KEY`.
`storage`, `cluster` and `vault` read the environment alone. A provider key
put in the vault is used at once; a `config.yaml` name, when the daemon next
starts. A key that is absent is reported by the tool that needs it; a
`config.yaml` that does not read stops the boot.

An agent is a Markdown file with YAML frontmatter, and the body is its system
prompt:

```markdown
---
description: Watches the incident queue and says what needs an engineer.
model: anthropic:claude-sonnet-5
tools: [web_search, linear/*]
org: acme
---
You watch the incident queue. Summarise anything new, and say which issues
need an engineer.
```

The daemon starts one agent per file when it boots, and `wardrik reload` gives
each running agent what its file says now without losing what it has said, and
stops the agent of a file that is gone, keeping its conversation until `wardrik
rm` removes it. An agent defined over the HTTP API is never touched by reading
the files, and one a file declares is changed only through its file.
An agent has only the tools its file lists; `linear/*` is every tool of the
server `config.yaml` calls `linear`, and `*` is everything it can reach. A file
that does not read is listed by `wardrik status`, and the others run regardless.

The file above is the agent `acme/triage`: every agent belongs to an org, and
one with `user: jon` is `acme/@jon/triage`. A file that names no `org` is in
`config.yaml`'s `org`, `default` unless it says, where the CLI finds an agent
by its name alone: `wardrik ask triage`. An MCP server and a notify target
serve that org's agents, unless their `org` names others or `*` for every
org.

An agent can be asked something on a clock:

```yaml
schedule:
  - name: sweep
    every: "*/30 * * * *"     # cron, in UTC; or a duration such as 30m or 1d
    prompt: Check the incident queue.
```

A schedule runs in the cluster once, whichever node holds it, and carries on
from the store on another node when its own is lost. A run that finds the
agent busy or waiting on a person lets it be, unless the schedule says
`overlap: queue`, and a daemon that was down past a run fires it once when it
comes back, unless the schedule says `missed: skip`. `wardrik status` shows when
each agent is asked next, and `wardrik schedules` when each schedule runs next
and when it last ran and what came of it. See `Wardrik.Schedule`.

An agent nobody is watching can tell someone when it parks on a question,
fails, or answers. `config.yaml` names the targets, and an agent file routes
to them:

```yaml
# ~/.config/wardrik/config.yaml
notify:
  ops:
    slack:
      channel: "#ops"
      token: ${SLACK_BOT_TOKEN}         # a bot token with chat:write
      app_token: ${SLACK_APP_TOKEN}     # Socket Mode: Approve and Deny buttons
      approvers: [U012ABCDEF]           # who may press them; anyone in the channel when absent
  audit:
    webhook:
      url: https://hooks.example.com/wardrik
      secret: ${WARDRIK_WEBHOOK_SECRET}    # signs each body, as x-wardrik-signature
```

```yaml
# in an agent file
notify: {to: [ops], on: [parked, failed, finished]}   # or just: notify: ops
```

A parked call reaches Slack with its arguments and the policy's question,
and pressing Approve or Deny answers it as `wardrik approve` would. The buttons
arrive over Slack's Socket Mode, a connection the daemon opens out to Slack,
so it needs no public address and no open port. Give the daemon a Slack app
of its own: another service connected with the same app shares its Socket Mode
envelopes. Without an `app_token` the message says which `wardrik approve` to run
instead. See `WardrikNotify`.

A policy decides what an agent's tools may do. It is a file in `policies/`,
named by the agents it governs as `policy: careful`, or written in place in an
agent file:

```yaml
# ~/.config/wardrik/policies/careful.yaml
allow: [web_search, linear/*]
ask:
  github/create_*: This opens an issue on GitHub.
deny: [run_lua]
default: allow
```

The strictest rule naming a call decides it. A call a policy asks about parks
the agent until a person answers, from the TUI or from a shell:

```sh
wardrik parked
wardrik approve acme/triage call_1
wardrik deny acme/triage call_1 Not on a Friday.
```

A rule may name what a call acts on, in parentheses, for a tool that says
what its calls act on. A deny or an ask on any one of them decides, and a
call is allowed by the rules only where they allow every one:

```yaml
allow: [write_file(notes/*)]
deny: [delete_file(*)]
```

Some tools are gated: a call to one waits on a person unless an `allow` rule
names it, and `default: allow` is not enough. An MCP server's tools are gated
unless the server marks them read-only, and `gated` in `config.yaml` decides
instead:

```yaml
mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    gated: [create_*, issue_write]   # or true, for every tool, or false, for none
```

Once a turn has read content from outside, a page `web_search` found, an
issue an MCP server returned, whatever a tool worker passed on, a gated tool's
calls wait on a person however the `allow` rules name them: what the turn read
may be what asked for the call. It stays in the conversation, so the turns
after it are held too, until `wardrik clear` empties it. `trusted: true` on an
MCP server, and `trusted_workers: true` under `http`, say their answers are
the deployment's own. `allow_after_outside` allows a tool that may follow what
a stranger wrote, because the agent reaches nothing they could take or the
tool can do little harm, even then:

```yaml
allow: [linear/*]
allow_after_outside: [github/add_labels]
```

An agent with `files` in its tools has a tree of its own to write in, kept
in the store with the agent, so its notes are on whichever node holds it and
survive the one it was on: `read_file`, `write_file`, `edit_file`,
`list_files`, `search_files` and `delete_file`. A change is made over the
version last read, so two writers never lose each other's work. `workspace`
shares trees between agents, each under `shared/<name>/`:

```yaml
tools: [files]
workspace:
  shared:
    team: acme                                  # acme's tree, for acme's agents
    runbooks: {tree: acme/runbooks, mode: read}
```

A tree is reachable by the agents under the scope its name begins with, and
holds only its own files: `acme` does not hold `acme/runbooks` or
`acme/@jon/notes`, so a tree shared only to read, or one only jon's agents
reach, stays that way however the trees above it are shared.

A file keeps who wrote it, and whether a turn that had read content from
outside wrote any of it, which an append or an edit keeps; reading, listing or
finding it taints the reader's turn in the same way. A policy names a file tool's call by its path, as
`write_file(notes/*)`. See `WardrikWorkspace`.

As each turn begins, the agent is told what its workspace holds: the files
`context` names, up to 16 KB of them in all unless `max_bytes` says, and the
names of the others at the top of its tree, which it reads when it needs them.
A file longer than its share is read from its start and its end, so a log kept
by appending keeps its newest lines in view, and the agent is asked to fold
it shorter. A `MEMORY.md` it keeps is there to find in every turn without
filling the context, and a schedule's `prompt_file` asks it to follow a file
it can edit, as a heartbeat:

```yaml
tools: [files]
context: [SOUL.md]
schedule:
  name: heartbeat
  every: 30m
  prompt_file: HEARTBEAT.md
```

A policy may also hold a budget for what the agent spends on model calls, in
dollars, in tokens, or both:

```yaml
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  on_exhausted: ask   # or deny
```

Once the agent has spent either limit it parks on its next model call, and
`wardrik parked` shows what it spent. Approving grants another limit's worth for
the period, or the budget's `grant`, and the agent carries on. `wardrik status`
shows each agent's spending. A token limit governs a model the catalog cannot
price, or one a subscription pays for.

A file is read into a value, not kept as one: an agent file into a
`Wardrik.Agent.Spec`, a policy file into a `WardrikPolicy`. The agent carries its
policy as `Wardrik.Hook`s, so it is written to the store with the agent and
decides the same way on whichever node holds it next. `wardrik reload` gives a
waiting agent the policy as it is now, which decides the calls it waits on.

The TUI is served over SSH once `~/.config/wardrik/ssh/authorized_keys` lists a
key, in OpenSSH's format. The daemon listens on port 2222 on loopback, a
client holding a listed key connects under any user name, and each connection
is a session of its own on the fleet:

```sh
ssh -p 2222 jon@localhost      # or: wardrik attach
ssh -L 2222:localhost:2222 box # a daemon on another machine, through a tunnel
```

The file is read at every login, so a key added or removed counts from the
next connection. Quitting ends the session and nothing else. `ssh:` in
`config.yaml` sets `port`, and `ip` to listen beyond loopback. The host key is
made on first start under `~/.local/share/wardrik/ssh`.

An MCP command sees only a few of the daemon's environment variables
(`HOME`, `PATH`, `USER` and the like) beside the ones its server sets, so the
cookie and every key the daemon holds stay with the daemon.
`WardrikMCP.Server`'s `:inherit_env` names others.

### Where it keeps things

Without `storage` in `config.yaml`, the daemon keeps agents, schedules,
tokens and sealed credentials on its own disk, replicated to the other nodes
of its cluster. `storage` keeps them in Postgres or S3 instead:

```yaml
# ~/.config/wardrik/config.yaml
storage:
  postgres:
    url: ${DATABASE_URL}          # postgres://user:pass@host/db, ?ssl=true for TLS
```

```yaml
storage:
  s3:
    bucket: wardrik
    endpoint: https://<account>.r2.cloudflarestorage.com
    region: auto
    access_key_id: ${R2_ACCESS_KEY_ID}
    secret_access_key: ${R2_SECRET_ACCESS_KEY}
```

On Postgres the daemon creates its table, `wardrik_records`, as it starts. In
a bucket everything is under `wardrik/`, or the `prefix` the `s3` section
names, one prefix to a namespace: an agent is
`wardrik/durable/agents/<org>/<user>/<name>`, its events are under
`wardrik/events/`, and each node's heartbeat is
`wardrik/durable/agents/__nodes/<node>`. The table holds the same keys, with
the namespace in `ns`. A bucket must refuse a write whose condition fails: the daemon checks as it
starts, and keeps nothing in one that does not. `wardrik doctor` runs the same
checks without starting the daemon.

A daemon on Postgres or S3 keeps nothing on its disk, so a new machine pointed
at the same store carries on with its agents, and nodes of a cluster start
and carry on without waiting for a quorum of the others.

### Several daemons, one cluster

`cluster` in `config.yaml` names the nodes, and each is started as one of
them. Three on one machine share the install and its config directory:

```yaml
# ~/.config/wardrik/config.yaml
cluster:
  nodes: [a, b, c]
```

```sh
wardrik start --node a   # a is waiting for 1 more node to reach a quorum of 2 of 3
wardrik start --node b
wardrik start --node c
wardrik status           # cluster of 3: a, b, c up
kill -9 "$(wardrik pid --node b)"
```

Their agents, schedules and store span all three, and the agents of a node
that is lost carry on on another, parked calls still parked. With the store on
the nodes, more than half of them make a quorum: three carry on with one lost.
A node starting waits until enough of the others are up, and `wardrik status`
says what it waits for.

`start`, `stop`, `serve`, `remote`, `logs` and `pid` act on one node and take
`--node` once there are several; every other command asks whichever node
answers, since each speaks for the whole cluster, and `reload` reads the files
again on every node. `WARDRIK_NODE` sets the node for every command.

Nodes on several machines are named in full, one to each, and listen on a
private network; see `WardrikDaemon.Cluster` and SECURITY.md:

```yaml
cluster:
  nodes: [wardrik@box1, wardrik@box2, wardrik@box3]   # or: dns: wardrik.internal, with size: 3
```

The daemon is `WardrikDaemon`, started as one of core's `:children`. A host of
its own adds to the tree the same way:

```elixir
config :wardrik, :children, [MyApp.Host]
```

| | |
| --- | --- |
| **`WARDRIK_NODE`** | which of `cluster.nodes` this is, as `--node` sets it: `a` runs as `wardrik_a@localhost` with a store and state directory of its own, and a full name as itself |
| **`WARDRIK_CONFIG_DIR`**, **`WARDRIK_STATE_DIR`** | the config and state directories, when not the XDG ones |
| **`WARDRIK_DATA_HOME`** | where the daemon keeps what it makes for itself, its host key among them, when not the XDG data home |
| **`WARDRIK_DATA_DIR`**, **`WARDRIK_COOKIE_FILE`** | the store and the cookie. `RELEASE_COOKIE` overrides the cookie file |
| **`WARDRIK_DIST_INTERFACE`** | the address distribution listens on, as an Erlang tuple. Defaults to loopback, where the node is `wardrikd@localhost`; `any` listens everywhere |
| **`WARDRIK_LOG`** | the log file, or `-` for the terminal |
| **`WARDRIK_HTTP_IP`**, **`WARDRIK_SSH_IP`** | the address the HTTP API and the TUI listen on where `config.yaml`'s `http.ip` and `ssh.ip` do not say, as the image sets them to `0.0.0.0` |
| **`WARDRIK_CLUSTER_SIZE`** | the store's voting members, where `config.yaml` has no `cluster` |

Anyone who can reach the distribution port with the cookie can run code on the
node. Listen beyond loopback only on a network you trust.

## License

Apache-2.0. See [LICENSE](LICENSE).
