# Wardrik

An agent runtime built on OTP. Agents carry on when a node is lost, and every
tool call they make goes through a policy you can read.

Each agent is a process: it holds its own conversation, takes one turn at a
time, and publishes everything it does to one event stream you can watch.
Stop the node it runs on mid-turn and it picks up on another, without running
a tool call twice. A call that needs a person waits for one, in the terminal,
over HTTP or in Slack.

Run it as a daemon with agents written as Markdown files, or add it to an
Elixir application as a library.

## Quick start

### The daemon

On Linux:

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | sh
wardrik init                                  # a first agent, its model and key, and the daemon
wardrik ask assistant "What can you do?"
```

Anywhere Docker runs:

```sh
docker run -d --name wardrik -p 127.0.0.1:4747:4747 \
  -v wardrik-config:/config -v wardrik:/data ghcr.io/wardrik-dev/wardrik
docker exec -it wardrik wardrik init
```

An agent is a Markdown file in `~/.config/wardrik/agents/`. Its frontmatter
says which model it runs and what it may use, and its body is what it is told:

```markdown
---
description: Watches the incident queue and says what needs an engineer.
model: anthropic:claude-sonnet-5
tools: [web_search, linear/*]
---
You watch the incident queue. Summarise anything new, and say which issues
need an engineer.
```

The [docs](https://docs.wardrik.dev) cover installing, agent files, policies,
triggers, Slack, storage and running several nodes as one cluster.

### The library

```elixir
def deps do
  [
    {:wardrik, "~> 0.1.0"},
    {:ekv, "~> 0.4.3"}
  ]
end
```

Start it in your application's tree, keeping everything on the node's disk:

```elixir
children = [{Wardrik, Wardrik.new(store: [data_dir: "/var/lib/my_app/wardrik"])}]
```

Then run an agent:

```elixir
config =
  Wardrik.LLM.Config.new(
    model_spec: {:anthropic, model: "claude-sonnet-5"},
    system: "You answer briefly."
  )

id = Wardrik.AgentID.new!("assistant", org: "acme", user: "42")

{:ok, _pid} = Wardrik.Fleet.spawn(id, config: config)
:ok = Wardrik.Event.Bus.subscribe(id)
:ok = Wardrik.Agent.ask(id, "What changed in Elixir this year?")
```

[Embed in your app](https://docs.wardrik.dev/build/embed/) keeps Wardrik in a
Phoenix app's own Postgres and lets its users reach their agents. See
[packages/wardrik_core](packages/wardrik_core) for the seams a host reaches
through: who an agent works for, which of its calls may run, and which model a
call lands on and who pays for it.

## How it fits together

**Core** (`wardrik_core`) runs agents, and only that. It has the fleet that keeps
one process per agent across a cluster, the turn loop, the contracts for
tools, hooks, credentials and stores, and the event stream. It ships no tools
and has no dependency you did not ask for.

**Packages** build on core, each one an application of its own that depends on
it: tools an agent calls, places to keep its state, where its credentials come
from, the policies that decide its calls, and the surfaces people reach it
through. Take the ones you need.

**Wardrik** (`wardrik`) puts core and the packages an application embeds
together behind one child, `{Wardrik, Wardrik.new(...)}`, kept in the
application's own store.

**The daemon** (`wardrik_daemon`) puts them together behind the `wardrik`
command, reading agents, policies and settings from files. The
[release](release) builds it into one self-contained binary and the Docker
image.

**SDKs** drive agents from other languages over the HTTP API, and offer them
tools that run in your own process.

## Packages

### Core

| Package | Description |
| --- | --- |
| [wardrik](packages/wardrik) | Wardrik inside your application, started as one child of your tree: definitions, policies and budgets, triggers, files, the vault, notices, stores in Postgres or S3, workflows and deep research |
| [wardrik_core](packages/wardrik_core) | The agent runtime: agents, the fleet, turns, tools, hooks and events, the store behaviour with its EKV and in-memory adapters, and the JSON Schemas every client is checked or generated against |

Core keeps agents on each node's disk with EKV where no other store is configured.

### Tools

| Package | Description |
| --- | --- |
| [wardrik_brave](packages/wardrik_brave) | Web search through Brave's LLM Context API, returning page content rather than links |
| [wardrik_mcp](packages/wardrik_mcp) | The tools of any MCP server, over stdio or HTTP, per user where the server needs it |
| [wardrik_lua](packages/wardrik_lua) | Lua 5.3 in a sandbox, for code an agent writes and runs |

### Accounts and channels

| Package | Description |
| --- | --- |
| [wardrik_oauth](packages/wardrik_oauth) | Accounts a user connects by authorizing, in a browser or on another device, renewed as they expire |
| [wardrik_channel](packages/wardrik_channel) | Chat media agents are reached through, such as Slack: the adapter behaviour, and notices posted in a room |
| [wardrik_slack](packages/wardrik_slack) | The Slack channel: notices in a room, with buttons that answer the calls an agent waits on |

### Surfaces

| Package | Description |
| --- | --- |
| [wardrik_http](packages/wardrik_http) | A versioned JSON API, each agent's events as server-sent events, and tool workers over a socket |
| [wardrik_tui](packages/wardrik_tui) | A terminal UI for agents, in a terminal or over SSH, and the console the `wardrik` command writes with |
| [wardrik_daemon](packages/wardrik_daemon) | The daemon and the `wardrik` command: agent files, policies, `config.yaml`, a cluster of nodes, and `mix wardrik` for trying agents in a terminal |

### SDKs

| SDK | Description |
| --- | --- |
| [TypeScript](sdks/typescript) | Drive agents over HTTP, and offer them tools from your own Node process |

## Working on Wardrik

Each package is a Mix project of its own under `packages/`, depending on the
packages it uses by path while they live here. Work in the one you are
changing:

```sh
cd packages/wardrik_mcp
mix deps.get
mix test
mix precommit   # formatting, credo, the architecture checks, tests with coverage, and dialyzer
```

| Directory | What it holds |
| --- | --- |
| `packages/` | the Elixir packages |
| `release/` | the daemon's release, and the configuration it boots with |
| `sdks/` | the SDKs for other languages |
| `docs/` | the docs site, whose reference pages `mix wardrik.docs` writes from the code |
| `tools/precommit` | `mix precommit` and the checks every package shares |
| `dev/` | scripts for running clusters, test services and the host apps CI builds |
| `deploy/` | the install script, and a server set up from scratch |

`dev/services.sh` starts the Postgres and S3 services some tests reach.

### Adding a package

A package is one of four kinds, and each kind is set up the same way:

| Kind | For example | Depends on | Implements | Its tests |
| --- | --- | --- | --- | --- |
| Plugin | `wardrik_brave`, `wardrik_mcp`, `wardrik_lua` | core, and the library it wraps | a core behaviour, such as `Wardrik.Tool`, `Wardrik.Hook` or `Wardrik.Credential` | call its callbacks, with core's `Wardrik.Test` helpers |
| Channel | `wardrik_slack` | `wardrik_channel`, and its client | `WardrikChannel` | deliver to and receive from a stubbed medium |
| Surface | `wardrik_http`, `wardrik_tui`, `wardrik_daemon` | core, and the packages it puts in front of people | nothing; it calls core | drive agents in the fleet |
| Assembly | `release` | the packages it ships | nothing | — |

In every one that builds on core:

- `mix.exs` names the packages beside it with `sibling(:wardrik)`, which is a
  path here and a version on Hex.
- It reads no application environment. Its settings come as the options of
  what the host starts, `{WardrikMCP.Supervisor, servers: [...]}`, or with
  the data the host plugs in; the daemon and the release are the hosts here,
  and read `config.yaml` for them.
- Its tests boot core with nothing to set up, on the store core keeps in
  memory:

  ```elixir
  # config/test.exs
  config :wardrik, WardrikStore, adapter: WardrikStore.Memory
  ```

To build the daemon:

```sh
cd release
MIX_ENV=prod mix release
_build/prod/rel/wardrikd/bin/wardrik init
```

## Security

Report a vulnerability as [SECURITY.md](SECURITY.md) describes, which also says
what the daemon trusts and what it does not.

## License

Apache-2.0. See [LICENSE](LICENSE).
