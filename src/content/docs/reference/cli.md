---
title: "CLI"
description: "Every command wardrik takes, and what each does."
editUrl: false
sidebar:
  order: 1
---

<!-- Written by mix wardrik.docs from WardrikDaemon.CLI.commands/0. Edit it there, not here. -->

rik is a short name for wardrik: `rik ls` is `wardrik ls`.

The daemon reads `config.yaml`, and the agents in `agents/`, from
`~/.config/wardrik`. `wardrik help COMMAND` says more about one.

Where `config.yaml` describes a cluster, `--node NAME`, or `WARDRIK_NODE`, is which
of its nodes a command is for. serve, start, stop, remote, logs, pid, doctor
and service need one when this install runs several; every other command asks
whichever node answers, since each speaks for the whole cluster.

## Set up

### wardrik init

Set up the front door agent, its model and key, and the daemon to run it.

```sh
wardrik init [--provider P] [--model M] [--agent NAME] [--key-from-env VAR] [--yes] [--no-service] [--no-ask]
```

It asks what it needs, says what it does, and writes no file that is there already. Without a terminal, `--provider`, `--model`, `--agent` and `--key-from-env VAR` answer, and `--yes` says yes. `--no-service` starts the daemon without systemd, and `--no-ask` asks the agent nothing.

### wardrik doctor

Check what the daemon reads, running or not.

```sh
wardrik doctor
```

### wardrik reload

Read the agent and policy files again, for every node.

```sh
wardrik reload
```

### wardrik help

Every command, or one in full.

```sh
wardrik help [COMMAND]
```

### wardrik completion

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

## Talk to agents

### wardrik ask

Send an agent a message, and follow its answer.

```sh
wardrik ask KEY MESSAGE [--no-wait]
```

It follows the turn as it goes, until it ends or waits on a person; Ctrl-C stops following, and the agent carries on. `--no-wait` only sends it.

### wardrik watch

Follow what an agent does, until Ctrl-C.

```sh
wardrik watch KEY [--json]
```

With `--json`, each event as `GET /v1/agents/KEY/events` streams it, a line each.

### wardrik history

What an agent has said.

```sh
wardrik history KEY
```

With `--json`, the agent as `GET /v1/agents/KEY` answers with it.

### wardrik clear

Empty an agent's conversation, and the labels of what it read.

```sh
wardrik clear KEY
```

An agent whose conversation holds content from outside asks a person before each gated call until it is cleared. Its files, triggers and config stay. Refused while it runs a turn or waits on a person.

### wardrik attach

The TUI, over SSH to HOST, localhost by default.

```sh
wardrik attach [HOST]
```

## Decide

### wardrik parked

The calls agents are waiting on a person for.

```sh
wardrik parked
```

With `--json`, each call as an interrupt, with the agent it is for.

### wardrik approve

Run a parked call, with a note for the agent.

```sh
wardrik approve [KEY [CALL [NOTE]]]
```

### wardrik deny

Refuse a parked call, saying why.

```sh
wardrik deny [KEY [CALL [REASON]]]
```

### wardrik policy judge

Try a policy's judge on the calls agents have made.

```sh
wardrik policy judge NAME [--agent KEY|PATTERN] [--last N]
```

Its model answers each question again, and what that decides is set beside how the call was decided; ! marks where they differ. The policy is read from its file as it is now, and nothing is decided or changed. The calls are those of the agents that run under the policy, or those `--agent` names, newest first, `--last` 20 by default. Only calls that ran are kept with their arguments, so a call refused, or waiting on a person, is not tried. With `--json`, each call with its answers, what they decide, and how it was decided.

## Manage agents

### wardrik ls

The agents, or those a query picks.

```sh
wardrik ls [QUERY]
```

A query is words that must all match: TEXT in the key, name:, org:, user:, node:, status:idle, status:running or status:parked, and attention, an agent waiting on a person. With `--json`, the agents as `GET /v1/agents` lists them.

### wardrik show

One agent in full: what it has and what it is doing.

```sh
wardrik show KEY
```

### wardrik triggers

When each trigger runs next, and how it last ran.

```sh
wardrik triggers [PATTERN]
```

### wardrik agent spawn

Start an agent, from `config.yaml`'s defaults if nothing defines it.

```sh
wardrik agent spawn NAME [--org ORG] [--user USER] [--on NODE] [--file]
```

It starts the agent `agents/NAME.md` declares, or one nothing defines from `config.yaml`'s defaults. `--file` writes `agents/NAME.md` from them first, and reads the files again, as `wardrik reload` does. `--org` and `--user` put it in an org, or with one of its users, and `--on NODE` starts it on that node. An agent `wardrik agent stop` stopped comes back with its conversation.

### wardrik agent cancel

End the turn an agent is taking; it keeps running.

```sh
wardrik agent cancel KEY|PATTERN [--all]
```

The messages waiting behind the turn go too, and a turn waiting on a person is abandoned. A PATTERN, such as `acme/agent/*`, ends the turns of every agent it covers, and `--all` those of every agent there is.

### wardrik agent stop

Stop an agent now, keeping its conversation; it wakes when asked again.

```sh
wardrik agent stop KEY
```

Anything asked of it by its key wakes it, as does `wardrik agent spawn`. `wardrik agent rm` removes it for good once no file declares it.

### wardrik agent rm

Remove an agent, its conversation and its triggers, for good.

```sh
wardrik agent rm KEY|PATTERN [--yes]
```

It lists what it removes and asks first; `--yes` removes without asking. A PATTERN, such as `acme/agent/*`, removes every agent it covers. An agent a file declares is left: remove the file, then `wardrik reload` removes it.

### wardrik agent move

Restart an agent on another node, with its conversation.

```sh
wardrik agent move KEY [NODE] [--yes]
```

Without NODE it asks which. Moving ends a turn the agent is taking, and abandons what it waits on a person for, so it asks first; `--yes` moves it without asking.

### wardrik agent calls

The tool calls an agent is running, and how long each has run.

```sh
wardrik agent calls KEY
```

With `--json`, the calls as `GET /v1/agents/KEY/calls` answers them.

### wardrik agent kill-call

Stop one tool call an agent is running; the rest of its turn goes on.

```sh
wardrik agent kill-call KEY CALL_ID
```

The model is answered with an error, as if the tool had failed. `wardrik agent calls` lists the calls; `wardrik agent cancel` ends the whole turn instead.

### wardrik agent edit

Edit the file that declares an agent, then read the files again.

```sh
wardrik agent edit KEY
```

It opens the file in $VISUAL, or $EDITOR, or vi.

## Tokens and secrets

### wardrik token create

A token for the HTTP API, printed once.

```sh
wardrik token create NAME --resource PATTERN... --role ROLES [--policy NAME] [--expires 30d]
```

`--resource PATTERN`, once or more, is what it reaches: `org/agent/*` (the org's own agents), `org/@user/*` (a user's), `org/*` (the org and all its users'), `org/agent/name` (one agent), or * (everything). `--role ROLES` is what it may do there, some of reader,messenger,approver,definer,worker,owner. `--policy NAME`, one of `policies/`, holds every agent it defines. `--expires` is how long it works, as 30d or 12h; tokens.expires.api by default. It acts for whoever made it.

### wardrik token list

The HTTP API's tokens.

```sh
wardrik token list
```

### wardrik token revoke

Stop a token working.

```sh
wardrik token revoke ID
```

### wardrik vault put

Seal secrets in the vault, asking for a value not given.

```sh
wardrik vault put NAME[=VALUE]... [--org ORG] [--user USER] [--yes]
```

NAME alone asks for its value without showing it, or reads it from standard input where that is not a terminal. NAME=VALUE stays in your shell's history. A secret is the deployment's, for model providers' keys and ${NAME} in `config.yaml`; no agent's call reads it. `--org ORG` seals it for an org, whose own agents read it, and `--user USER` for a user, whose agents read it, within `--org ORG` or the deployment's org. Where the vault has no key, it asks to make one; `--yes` makes it without asking.

### wardrik vault ls

The vault's secrets and whose they are, never their values.

```sh
wardrik vault ls [--org ORG] [--user USER]
```

`--org ORG` or `--user USER` lists one owner's. With `--json`, each as its name, kind and owner; the deployment's say whether the daemon's environment sets them.

### wardrik vault rm

Remove a secret from the vault.

```sh
wardrik vault rm NAME [--org ORG] [--user USER]
```

## Run the daemon

### wardrik serve

Run the daemon here, logging to the terminal.

```sh
wardrik serve
```

### wardrik start

Run the daemon in the background.

```sh
wardrik start
```

### wardrik stop

Stop the daemon, and wait until it has.

```sh
wardrik stop
```

### wardrik status

What the daemon, or its cluster, is running.

```sh
wardrik status
```

With `--json`, the nodes as `GET /v1/deployment/nodes` lists them.

### wardrik audit

What people changed, oldest first.

```sh
wardrik audit [--after N] [--limit N]
```

Up to `--limit` changes, 100 unless given, after the change numbered `--after`. With `--json`, the page as `GET /v1/deployment/audit` answers it.

### wardrik service install

Run the daemon under your user's systemd.

```sh
wardrik service install
```

### wardrik service uninstall

Stop the service, and remove its unit.

```sh
wardrik service uninstall
```

### wardrik service status

How systemd has the service.

```sh
wardrik service status
```

### wardrik service unit

Print the unit install writes.

```sh
wardrik service unit
```

### wardrik remote

An IEx shell on the daemon.

```sh
wardrik remote
```

### wardrik logs

Follow the daemon's log.

```sh
wardrik logs
```

### wardrik pid

The daemon's process id.

```sh
wardrik pid
```

### wardrik version

Print the version.

```sh
wardrik version
```
