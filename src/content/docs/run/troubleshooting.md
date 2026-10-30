---
title: Troubleshooting
description: "Three commands answer most questions: status, doctor and logs. Then the common problems and their fixes."
sidebar:
  order: 8
---

Three commands answer most questions: `wardrik status` for whether the daemon runs, `wardrik doctor`
for whether its config will work, and `wardrik logs` for what it said.

## See whether it runs

```sh
wardrik status
```

```
Wardrik runs at http://127.0.0.1:4747.
NODE               AGENTS
wardrik@localhost  3
2 asleep
```

When nothing answers, it says so and exits with 1:

```
wardrik: Nothing answers at http://127.0.0.1:4747. Start the daemon with `wardrik start`.
```

For the agents themselves, `wardrik ls` lists each with what it's doing, and
`wardrik agent show AGENT` says more about one. `wardrik follow AGENT` follows what it does.

## Check its config

```sh
wardrik doctor
```

```
ok    env            /home/me/.config/wardrik/env sets 3 variables
ok    config         /home/me/.config/wardrik/config.yaml reads
ok    storage        keeps everything on this node's disk, under /home/me/.local/share/wardrik/store
ok    vault          1 key from /home/me/.local/share/wardrik/vault_key, which seals
warn  brave          web_search has no key; give it brave.api_key
ok    mcp github     answers at api.githubcopilot.com:443
FAIL  mcp notes      runs npx, which isn't on this machine's PATH
ok    agents         2 agent files and 1 policy read
```

It reads what the daemon reads, in a process of its own, so it works on a daemon that won't start.
It exits with 1 when a check fails.

## Read its log

```sh
wardrik logs
```

This follows the log of a daemon `wardrik start` started, in `~/.local/state/wardrik/log/`. Where
else the log goes depends on how the daemon runs:

| Started with | The log is |
| --- | --- |
| `wardrik start` | `wardrik logs` |
| `wardrik serve` | the terminal |
| `wardrik service install` | `journalctl --user -u wardrik -f` |

What an MCP server run as a command writes to standard error is in the same log.

## Common problems

**The daemon doesn't start.** `wardrik start` returns before the daemon is up, so check with
`wardrik status`. Then run `wardrik doctor`. Usually `config.yaml` doesn't read, and the line says
where:

```
FAIL  config         /home/me/.config/wardrik/config.yaml: http.port: is a port number
```

**`config.yaml` names a `${NAME}` nothing sets.** The daemon won't start, and
`wardrik vault put` needs a running daemon. Set the name in `~/.config/wardrik/env`, and start
again. `wardrik doctor` lists names it expects the vault to hold:

```
ok    config         /home/me/.config/wardrik/config.yaml reads; the vault must hold LINEAR_TOKEN
```

**An agent file isn't running as written.** `wardrik doctor` names each file that doesn't read,
and why. Fix the file and run `wardrik reload`, which prints what still doesn't read. Until then,
the agent carries on as it was.

**An agent lacks a server's tools.** The daemon reads `config.yaml` as it starts, so a new server
needs a restart. A server that's down offers no tools until it's back.

**A policy change didn't take.** The daemon reads `policies/` as it starts. Restart it.

**The HTTP API doesn't answer.** Another process may hold port 4747. Set `http.port` in
`config.yaml`, and restart.

**An agent stopped answering.** `wardrik ls attention` lists agents waiting on a person.
`wardrik approval ls` shows each call they wait on. `wardrik agent history AGENT` shows how its last
turns ended.

**A trigger didn't run.** `wardrik trigger ls AGENT` lists its triggers, how each runs, and when it
runs next.

**`wardrik` says the daemon hasn't started here yet.** The command reads its token from
`~/.local/share/wardrik/cli_token`, which the daemon writes as it starts. Start the daemon, or set
`WARDRIK_URL` and `WARDRIK_TOKEN` to reach one elsewhere.

## Details

### `wardrik doctor`'s checks

| Check | What it looks at |
| --- | --- |
| `env` | that the env file is yours alone, and every line sets a variable |
| `config` | that `config.yaml` reads. If it doesn't, no later check runs. |
| `storage` | for Postgres, that its host answers; for the disk, where the store is |
| `vault` | that each key, from `vault.keys`, `WARDRIK_VAULT_KEY` or `vault_key`, is 32 bytes of base64 |
| `brave` | whether `web_search` has a key |
| `mcp NAME` | for a command, that it's on the `PATH`; over HTTP, that its host answers. It doesn't start the server or speak MCP. |
| `channel NAME` | how the channel takes Slack's events, its tokens, and who decides |
| `oauth` | that `base_url` reaches the daemon, once a provider needs a callback. See [A public address](/run/public-address/). |
| `agents` | that every agent and policy file reads, as the daemon would start it |

It runs with your shell's environment and `PATH`, which may differ from the service's.

### Environment and secrets

- A `${NAME}` the environment doesn't set comes from the env file, then from the vault, as the
  daemon starts.
- `storage`, `http` and `vault` read the environment and the env file alone.
- The env file is one `NAME=value` a line, with an optional `export` and optional quotes.
- Every `wardrik` command, and the daemon, reads it for what the shell doesn't set.

### Servers and `PATH`

A program `wardrik doctor` finds but the service doesn't is on your shell's `PATH` and not
systemd's. Name it by its full path.

### Requests

Each HTTP answer carries a `request-id` header. A request that sends one gets its own back.
