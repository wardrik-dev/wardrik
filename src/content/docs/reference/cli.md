---
title: "CLI"
description: "Every command wardrik takes, and what each does."
editUrl: false
sidebar:
  order: 1
---

<!-- Written by mix wardrik.docs from WardrikDaemon.CLI.commands/0. Edit it there, not here. -->

The daemon reads config.yaml, and the agents in agents/, from
~/.config/wardrik. wardrik help COMMAND says more about one.

Where config.yaml describes a cluster, --node NAME, or WARDRIK_NODE, is which
of its nodes a command is for. serve, start, stop, remote, logs, pid, doctor
and service need one when this install runs several; every other command asks
whichever node answers, since each speaks for the whole cluster.

## wardrik serve

Run the daemon here, logging to the terminal.

```sh
wardrik serve
```

## wardrik start

Run the daemon in the background.

```sh
wardrik start
```

## wardrik stop

Stop the daemon, and wait until it has.

```sh
wardrik stop
```

## wardrik status

What the daemon, or its cluster, is running.

```sh
wardrik status
```

With --json, the agents as GET /v1/agents lists them.

## wardrik doctor

Check what the daemon reads, running or not.

```sh
wardrik doctor
```

## wardrik reload

Read the agent and policy files again, everywhere.

```sh
wardrik reload
```

## wardrik ask

Send an agent a message, and follow its answer.

```sh
wardrik ask KEY MESSAGE [--no-wait]
```

It follows the turn as it goes, until it ends or waits on a person; Ctrl-C stops following, and the agent carries on. --no-wait only sends it.

## wardrik watch

Follow what an agent does, until Ctrl-C.

```sh
wardrik watch KEY [--json]
```

With --json, each event as GET /v1/agents/KEY/events streams it, a line each.

## wardrik history

What an agent has said.

```sh
wardrik history KEY
```

With --json, the agent as GET /v1/agents/KEY answers with it.

## wardrik ls

The agents, or those a query picks.

```sh
wardrik ls [QUERY]
```

A query is words that must all match: TEXT in the key, name:, org: and user: (_ for none), node:, status:idle, status:running or status:parked, and attention, an agent waiting on a person. With --json, the agents as GET /v1/agents lists them.

## wardrik show

One agent in full: what it has and what it is doing.

```sh
wardrik show KEY
```

## wardrik schedules

When each schedule runs next, and how it last ran.

```sh
wardrik schedules [PREFIX]
```

## wardrik parked

The calls agents are waiting on a person for.

```sh
wardrik parked
```

With --json, each call as an interrupt, with the agent it is for.

## wardrik approve

Run a parked call, asking which where not named.

```sh
wardrik approve [KEY [CALL]]
```

## wardrik deny

Refuse a parked call, saying why.

```sh
wardrik deny [KEY [CALL [REASON]]]
```

## wardrik token create

A token for the HTTP API, printed once.

```sh
wardrik token create NAME (--scope PREFIX | --all) [--can ACTIONS] [--policy NAME | --unlimited]
```

--scope PREFIX is the agents it reaches: org/, org/user/ or a key, org/user/name. --can ACTIONS limits it to some of read,message,decide,define,serve. A token that can define holds the agents it defines to --policy NAME, one of policies/, or to their own policies alone with --unlimited.

## wardrik token list

The HTTP API's tokens.

```sh
wardrik token list
```

## wardrik token revoke

Stop a token working.

```sh
wardrik token revoke ID
```

## wardrik service install

Run the daemon under your user's systemd.

```sh
wardrik service install
```

## wardrik service uninstall

Stop the service, and remove its unit.

```sh
wardrik service uninstall
```

## wardrik service status

How systemd has the service.

```sh
wardrik service status
```

## wardrik service unit

Print the unit install writes.

```sh
wardrik service unit
```

## wardrik attach

The TUI, over SSH to HOST, localhost by default.

```sh
wardrik attach [HOST]
```

## wardrik remote

An IEx shell on the daemon.

```sh
wardrik remote
```

## wardrik logs

Follow the daemon's log.

```sh
wardrik logs
```

## wardrik pid

The daemon's process id.

```sh
wardrik pid
```

## wardrik version

Print the version.

```sh
wardrik version
```

## wardrik help

Every command, or one in full.

```sh
wardrik help [COMMAND]
```

## wardrik completion

Completion for bash, zsh or fish, to install.

```sh
wardrik completion SHELL
```

It completes commands, options, and the keys and calls of the agents running.

```sh
wardrik completion bash > ~/.local/share/bash-completion/completions/wardrik
wardrik completion zsh > "${fpath[1]}/_wardrik"
wardrik completion fish > ~/.config/fish/completions/wardrik.fish
```
