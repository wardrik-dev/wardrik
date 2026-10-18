---
title: Troubleshooting
description: "Three commands answer most questions: status, doctor and logs. Then the common problems and their fixes."
sidebar:
  order: 8
---

Three commands answer most questions: `wardrik status` for what the daemon runs, `wardrik doctor`
for whether its config will work, and `wardrik logs` for what it said.

## See what it runs

```sh
wardrik status
```

```
wardrik 0.1.0 on wardrikd@localhost, up 3h 12m
2 agents
  default/triage  idle  wardrikd@localhost  $0.84 of $5.00 today  next run in 12m
  acme/deploy  parked  wardrikd@localhost

1 file does not read:
  /home/me/.config/wardrik/agents/notes.md: tools names notes/*, but config.yaml configures no server notes; it has github, linear
```

It lists the node, the cluster's nodes if any, each agent and what it's doing, and each file that
doesn't read, with why. `wardrik ls`, `wardrik show KEY` and `wardrik parked` say more about agents;
`wardrik watch KEY` follows one.

## Check its config

```sh
wardrik doctor
```

```
ok    config      /home/me/.config/wardrik/config.yaml reads
ok    store       on this node's disk, at /home/me/.local/share/wardrik/store
ok    vault       1 key, which seals
ok    mcp github  answers at api.githubcopilot.com:443; each user authorizes it
FAIL  mcp files   runs npx, which is not on this machine's PATH
ok    agents      2 agent files and 1 policy read
```

It checks the config, the store, the vault's keys, each MCP server, and every agent and policy file.
It runs on its own, so it works on a daemon that won't start.

## Read its log

```sh
wardrik logs
```

This follows `~/.local/state/wardrik/log/wardrik.log`. What MCP servers run as commands write to
standard error is in `mcp.log`, beside it.

## Common problems

**`wardrik start` says it didn't start.** It prints the end of the log. Usually `config.yaml`
doesn't read, and the log says where:

```
config.yaml: mcp.linear.headers.authorization names ${LINEAR_TOKEN}, which is not set
```

Seal the name with `wardrik vault put LINEAR_TOKEN`, or set it in `~/.config/wardrik/env`, and start
again.

**An agent file isn't running as written.** `wardrik status` lists files that don't read. Fix the
file and run `wardrik reload`. Until then, the agent carries on as it was.

**An agent lacks a server's tools.** `config.yaml` is read at start, so a new server needs a
restart. A server that's down offers no tools until it's back.

**A node waits, and commands say the store is unavailable.** It's waiting for a quorum.
`wardrik status` says how many more nodes it needs; see [Run a cluster](/run/cluster/#quorum).

**The HTTP API or terminal client doesn't answer.** Another process holds its port. The log says so,
and the daemon retries every five seconds.

**An agent stopped answering.** `wardrik ls attention` lists agents waiting on a person, and
`wardrik parked` shows what each waits on: a call, an account to connect, a spent budget, or a model
that kept failing. `wardrik show KEY` says why its last turn failed.

**A trigger didn't run.** `wardrik triggers` says how each last ran: asked, nothing new, skipped
while busy, or a missed run let go.

**A token gets `503`.** The node can't read tokens from the store right now, as in a cluster
without a quorum.

## Details

### `wardrik status`

It exits with 3, saying `wardrik is not running`, when no daemon answers.

### `wardrik doctor`'s checks

- **`config`**: that `config.yaml` reads. If it doesn't, this is the only line.
- **`store`**: that the store is there and behaves as needed. For a bucket it writes a probe under
  `wardrik/probe/`; for Postgres it connects.
- **`vault`**: that each key, from `vault.keys`, `WARDRIK_VAULT_KEY` or
  `~/.local/share/wardrik/vault_key`, is one the vault can use, and that there is one where OAuth or
  a server's credential needs it.
- **`mcp NAME`**: for a command, that its program is on the `PATH`; over HTTP, that its host
  answers. It doesn't start the server or speak MCP.
- **`agents`**: that every agent and policy file reads, with a line for each that doesn't.

It exits with 1 when a check fails. It runs with your shell's environment and `PATH`, which may
differ from the service's. For a daemon that runs, it also asks whether the vault holds each name.

### Logs

- The log rotates at 10 MB, keeping five.
- `wardrik serve` logs to the terminal, and the Docker image to `docker logs`.
- `WARDRIK_LOG` names another file, or `-` for the terminal.
- Each HTTP request is logged with its `request-id`, the header every answer carries.

### Environment and secrets

A name the environment doesn't set is read from the vault, when the daemon next starts. `storage`,
`cluster`, `http` and `vault` read the environment alone. Every `wardrik` command, and the service,
reads `~/.config/wardrik/env`, one `NAME=value` a line, for what the shell doesn't set.

### Servers and `PATH`

A server's log lines are in `wardrik.log`, and what a command wrote is in `mcp.log`. A program
`wardrik doctor` finds but the service doesn't is on your shell's `PATH` and not systemd's: name it
by its full path.
