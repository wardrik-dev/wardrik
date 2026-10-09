---
title: Troubleshooting
description: Find out what the daemon is doing, whether what it reads will do, and what its log says.
sidebar:
  order: 6
---

Three commands answer most questions: `wardrik status` for what the daemon is running,
`wardrik doctor` for whether what it reads will do, and `wardrik logs` for what it said.

## What it is running

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

It shows the node and how long it has been up, the cluster's nodes where there is one, each agent
with what it is doing and where, and each agent or policy file that does not read, with why.
`wardrik status` exits with 3, saying `wardrik is not running`, where no daemon answers.

`wardrik ls`, `wardrik show KEY` and `wardrik parked` say more about the agents, and
`wardrik watch KEY` follows what one does.

## Whether what it reads will do

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

It checks, a line each:

- **`config`**: that `config.yaml` reads. Where it does not, this is the only line.
- **`store`**: that the store is there and behaves as the daemon needs. For a bucket, this writes a
  probe under `wardrik/probe/`; for Postgres, it connects.
- **`vault`**: that each key is one the vault can use, from `vault.keys`, `WARDRIK_VAULT_KEY` or
  `~/.local/share/wardrik/vault_key`, and that there is one where OAuth or a server's credential
  needs it.
- **`mcp NAME`**: for a server run as a command, that its program is on the `PATH`; for one over
  HTTP, that its host answers. It does not start the server or speak MCP to it.
- **`agents`**: that every agent and policy file reads, with a line for each that does not.

It runs on its own, so it checks a daemon that will not start as well as one that runs, and exits
with 1 where a check fails. It runs with your shell's environment and `PATH`, which may not be the
service's.

## What it said

```sh
wardrik logs
```

follows `~/.local/state/wardrik/log/wardrik.log`. The log is rotated at 10 MB, keeping five.
`wardrik serve` logs to the terminal instead, and so does the Docker image, to `docker logs`.
`WARDRIK_LOG` names another file, or `-` for the terminal.

What MCP servers run as commands write to their standard error is in `mcp.log`, beside it.

Each HTTP request is logged with its `request-id`, the header every answer carries.

## When something is wrong

**`wardrik start` says it did not start.** It prints the end of the log. A `config.yaml` that does
not read stops the daemon starting, and says where:

```
config.yaml: mcp.linear.headers.authorization names ${LINEAR_TOKEN}, which is not set
```

A name the environment does not set is read from the vault, so `wardrik vault put LINEAR_TOKEN`
seals it, and the daemon reads it when it next starts; `storage`, `cluster`, `http` and `vault`
read the environment alone. `wardrik doctor` says the same without starting it, and asks a daemon that runs
whether the vault holds each name. Every `wardrik` command, and the service, reads
`~/.config/wardrik/env` too, one `NAME=value` a line, for what the shell it runs in does not set.

**An agent file is not running as written.** A file that does not read is listed by
`wardrik status`, and the agent it declared, if one runs, carries on as it was. Fix the file and run
`wardrik reload`.

**An agent does not have a server's tools.** `config.yaml` is read when the daemon starts, so a
server added since needs a restart. A server that is down offers no tools until it is back; its log
lines are in `wardrik.log`, and what a command wrote in `mcp.log`. A program `wardrik doctor` finds
and the service does not is on your shell's `PATH` and not on systemd's: name it by its full path.

**A node waits, and commands answer that the store is unavailable.** It is waiting for a quorum of
its cluster. `wardrik status` says how many more nodes it needs. See
[Run a cluster](/operate/cluster/#quorum).

**The HTTP API or the terminal client does not answer.** Another process holds its port. The daemon
says so in its log, and tries again every five seconds.

**An agent has stopped answering.** `wardrik ls attention` lists the agents waiting on a person, and
`wardrik parked` what each waits on: a call to approve, an account to connect, or a budget spent.
`wardrik show KEY` says why an agent's last turn failed.

**A schedule did not run.** `wardrik schedules` says how each last ran: asked, skipped because the
agent was busy, or a missed run let go.

**A token gets `503`.** The node cannot read tokens from the store just now, as in a cluster without
a quorum.
