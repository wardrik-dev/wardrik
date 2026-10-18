# wardrik_daemon

The [Wardrik](../wardrik) daemon, and the `wardrik` command that runs it. It
reads agents, policies and settings from files, keeps the agents running,
and serves them over HTTP, over SSH to the TUI, and in Slack.

Install the release on Linux, or run the Docker image:

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | sh
wardrik init
```

The [docs](https://docs.wardrik.dev) cover
[agent files](https://docs.wardrik.dev/reference/agent-files/),
[policies](https://docs.wardrik.dev/reference/policies/),
[`config.yaml`](https://docs.wardrik.dev/reference/config/),
[storage](https://docs.wardrik.dev/run/storage/) and
[clusters](https://docs.wardrik.dev/run/cluster/) in full.

## The command

```sh
wardrik init                      # a first agent, its model and key, and the daemon
wardrik start                     # in the background; `serve` runs it in the foreground
wardrik status                    # what it is running
wardrik ask triage "What changed today?"   # and follow the answer
wardrik watch triage              # follow what it does, until Ctrl-C
wardrik parked                    # what is waiting on a person
wardrik approve triage call_1     # or deny, with a reason
wardrik agent spawn helper        # write agents/helper.md from config.yaml's defaults, and start it
wardrik agent move triage b       # start it again on node b, as it was
wardrik agent cancel triage       # stop what it is doing, and leave it running
wardrik reload                    # read the agent and policy files again
wardrik vault put LINEAR_TOKEN    # seal a secret, asking for its value
wardrik token create ci --scope acme/ --role reader,messenger
wardrik doctor                    # whether config.yaml, the store, the vault and each agent file will do
wardrik service install           # run it under your user's systemd
wardrik stop
```

`wardrik help` lists every command, and `wardrik help COMMAND` gives one in
full. `status`, `ls`, `history`, `parked` and `vault ls` take `--json`.
`wardrik completion bash`, `zsh` or `fish` completes commands, options and the
agents running.

A command that changes something, and the same change made in the TUI or over
the HTTP API, is recorded in `Wardrik.Audit` with who made it: the account
that ran `wardrik`, the SSH user, or whoever made the token. Each acts with a
token whose roles say what they may do: a shell or the TUI holds `owner` on
every agent, someone in a channel what [`channels`](guides/config.md#channels)
says, and an API token what `wardrik token create` gave it.

## Where it keeps things

| Path | What it holds |
| --- | --- |
| `~/.config/wardrik/config.yaml` | MCP servers, OAuth providers, notify targets, the cluster and the store |
| `~/.config/wardrik/agents/*.md` | the agents it runs, one per file |
| `~/.config/wardrik/policies/*.yaml` | the policies agents name |
| `~/.config/wardrik/ssh/authorized_keys` | who may reach the TUI over SSH |
| `~/.local/share/wardrik/store/` | the store, where `config.yaml` names no other |
| `~/.local/share/wardrik/vault_key` | the vault's key, made by the first `wardrik vault put` |
| `~/.local/state/wardrik/log/` | `wardrik.log`, and `mcp.log` for what MCP commands write to stderr |

`XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME` move them, so
`~/.config/wardrik` holds only what a person writes and can live in a dotfiles
repository.

## In Docker

The image runs `wardrik serve`, logging to the container's output, with
`wardrik` on its `PATH` for `docker exec`:

| | |
| --- | --- |
| `/config` | `config.yaml`, `agents/` and `policies/`. A volume, or a directory of yours that uid 1000 can write |
| `/data` | the store, the cookie, the SSH host key and the vault's key. A volume, so a new container on it carries on |
| `4747`, `2222` | the HTTP API, and the TUI over SSH |

```sh
docker run -d --name wardrik \
  -p 127.0.0.1:4747:4747 -p 2222:2222 \
  -v wardrik-config:/config -v wardrik:/data ghcr.io/wardrik-dev/wardrik
docker exec -it wardrik wardrik init
```

## Environment

| Variable | What it sets |
| --- | --- |
| `WARDRIK_NODE` | which of `cluster.nodes` this is, as `--node` sets it |
| `WARDRIK_CONFIG_DIR`, `WARDRIK_STATE_DIR` | the config and state directories, when not the XDG ones |
| `WARDRIK_DATA_HOME` | where the daemon keeps what it makes for itself, when not the XDG data home |
| `WARDRIK_DATA_DIR`, `WARDRIK_COOKIE_FILE` | the store and the cookie; `RELEASE_COOKIE` overrides the cookie file |
| `WARDRIK_DIST_INTERFACE` | the address distribution listens on: loopback unless set, `any` for everywhere |
| `WARDRIK_LOG` | the log file, or `-` for the terminal |
| `WARDRIK_HTTP_IP`, `WARDRIK_SSH_IP` | where the HTTP API and the TUI listen, where `config.yaml` does not say |
| `WARDRIK_CLUSTER_SIZE` | the store's voting members, where `config.yaml` has no `cluster` |

Anyone who can reach the distribution port with the cookie can run code on the
node, so listen beyond loopback only on a network you trust. See
[SECURITY.md](../../SECURITY.md).

## In an application of your own

The daemon is an application: a project that depends on it starts it, as
`WardrikDaemon.Application`. An application of your own runs agents through
[wardrik](../wardrik) instead, started as one child of its tree.

## The release

`wardrikd`: this package and every package it ships, with its own ERTS, as one
directory and a tarball. `bin/wardrik` is the command a person runs and
`bin/wardrikd` the node's own script.

```sh
MIX_ENV=prod mix release
_build/prod/rel/wardrikd/bin/wardrik init
```

`WardrikDaemon.Application` is the release's tree. `config/` is what it boots
with: `config.exs` and `prod.exs` when it is built, and `runtime.exs` each time
it starts, which reads `config.yaml`'s storage, cluster and http. `rel/` is the
script that gives each install a cookie of its own and keeps distribution on
loopback, and the `wardrik` command. The tests and `mix wardrik` start what the
daemon depends on, and not that tree.

The `Dockerfile` at the root of the repository builds the image and the
tarball the install script installs, on Ubuntu 22.04, so the tarball runs on
any Linux with glibc 2.35 and OpenSSL 3.
