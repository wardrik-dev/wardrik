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

## wardrik init

Set up a first agent, its model and key, and the daemon to run it.

```sh
wardrik init [--provider P] [--model M] [--agent NAME] [--key-from-env VAR] [--yes] [--no-service] [--no-ask]
```

It asks what it needs, says what it does, and writes no file that is there already. Without a terminal, --provider, --model, --agent and --key-from-env VAR answer, and --yes says yes. --no-service starts the daemon without systemd, and --no-ask asks the agent nothing.

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

With --json, the nodes as GET /v1/deployment/nodes lists them.

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

## wardrik audit

What people changed, oldest first.

```sh
wardrik audit [--after N] [--limit N]
```

Up to --limit changes, 100 unless given, after the change numbered --after. With --json, the page as GET /v1/deployment/audit answers it.

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

## wardrik clear

Empty an agent's conversation, and the labels of what it read.

```sh
wardrik clear KEY
```

An agent whose conversation holds content from outside asks a person before each gated call until it is cleared. Its files, triggers and config stay. Refused while it runs a turn or waits on a person.

## wardrik ls

The agents, or those a query picks.

```sh
wardrik ls [QUERY]
```

A query is words that must all match: TEXT in the key, name:, org:, user:, node:, status:idle, status:running or status:parked, and attention, an agent waiting on a person. With --json, the agents as GET /v1/agents lists them.

## wardrik show

One agent in full: what it has and what it is doing.

```sh
wardrik show KEY
```

## wardrik triggers

When each trigger runs next, and how it last ran.

```sh
wardrik triggers [PREFIX]
```

## wardrik agent spawn

Start an agent, writing its file from config.yaml's defaults if it has none.

```sh
wardrik agent spawn NAME [--org ORG] [--user USER] [--on NODE]
```

It starts the agent agents/NAME.md declares, writing the file first where there is none, and reads the files again, as wardrik reload does. --org and --user put it in an org, or with one of its users, and --on NODE starts it on that node. An agent wardrik agent stop stopped comes back with its conversation.

## wardrik agent cancel

End the turn an agent is taking; it keeps running.

```sh
wardrik agent cancel KEY|PREFIX/ [--all]
```

The messages waiting behind the turn go too, and a turn waiting on a person is abandoned. A PREFIX/, such as acme/, ends the turns of every agent under it, and --all those of every agent there is.

## wardrik agent stop

Stop an agent now, keeping its conversation; it wakes when asked again.

```sh
wardrik agent stop KEY
```

Anything asked of it by its key wakes it, as does wardrik agent spawn. wardrik agent rm removes it for good once no file declares it.

## wardrik agent rm

Remove an agent, its conversation and its triggers, for good.

```sh
wardrik agent rm KEY|PREFIX/ [--yes]
```

It lists what it removes and asks first; --yes removes without asking. A PREFIX/, such as acme/, removes every agent under it. An agent a file declares is left: remove the file, then wardrik reload removes it.

## wardrik agent move

Restart an agent on another node, with its conversation.

```sh
wardrik agent move KEY [NODE] [--yes]
```

Without NODE it asks which. Moving ends a turn the agent is taking, and abandons what it waits on a person for, so it asks first; --yes moves it without asking.

## wardrik agent edit

Edit the file that declares an agent, then read the files again.

```sh
wardrik agent edit KEY
```

It opens the file in $VISUAL, or $EDITOR, or vi.

## wardrik parked

The calls agents are waiting on a person for.

```sh
wardrik parked
```

With --json, each call as an interrupt, with the agent it is for.

## wardrik approve

Run a parked call, with a note for the agent.

```sh
wardrik approve [KEY [CALL [NOTE]]]
```

## wardrik deny

Refuse a parked call, saying why.

```sh
wardrik deny [KEY [CALL [REASON]]]
```

## wardrik policy judge

Try a policy's judge on the calls agents have made.

```sh
wardrik policy judge NAME [--agent KEY|PREFIX/] [--last N]
```

Its model answers each question again, and what that decides is set beside how the call was decided; ! marks where they differ. The policy is read from its file as it is now, and nothing is decided or changed. The calls are those of the agents that run under the policy, or those under --agent, newest first, --last 20 by default. Only calls that ran are kept with their arguments, so a call refused, or waiting on a person, is not tried. With --json, each call with its answers, what they decide, and how it was decided.

## wardrik token create

A token for the HTTP API, printed once.

```sh
wardrik token create NAME (--scope PREFIX | --all) [--can ACTIONS] [--policy NAME | --unlimited] [--for NAME]
```

--scope PREFIX is the agents it reaches: org/, org/@user/, or a key, org/name or org/@user/name. --can ACTIONS limits it to some of read,message,decide,define,serve. A token that can define holds the agents it defines to --policy NAME, one of policies/, or to their own policies alone with --unlimited. --for NAME is the person it is issued to, whom its decisions are recorded as made by.

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

## wardrik vault put

Seal secrets in the vault, asking for a value not given.

```sh
wardrik vault put NAME[=VALUE]... [--org ORG] [--user USER] [--yes]
```

NAME alone asks for its value without showing it, or reads it from standard input where that is not a terminal. NAME=VALUE stays in your shell's history. A secret is the deployment's, which credential: NAME reads where nothing more specific holds NAME. --org ORG seals it for an org, whose agents read it first, and --user USER for a user, within --org ORG or the deployment's org. Where the vault has no key, it asks to make one; --yes makes it without asking.

## wardrik vault ls

The vault's secrets and whose they are, never their values.

```sh
wardrik vault ls [--org ORG] [--user USER]
```

Users' secrets are counted by name; --user USER lists one user's. With --json, each as its name, kind, and owner as --org and --user take it, or the count of users with it; the deployment's say whether the daemon's environment sets them.

## wardrik vault rm

Remove a secret from the vault.

```sh
wardrik vault rm NAME [--org ORG] [--user USER]
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
