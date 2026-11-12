---
title: "CLI"
description: "Wardrik CLI commands, flags, and examples."
sidebar:
  order: 1
---

Use `wardrik` to manage agents, approve calls, and operate the daemon.

```sh
wardrik agent ls
wardrik ask triage "What's new?"
wardrik approval approve triage toolu_01 --note "Only this once."
```

- `rik` is an alias: `rik ls` is `wardrik ls`.
- `wardrik help COMMAND`, or `COMMAND --help`, prints a command's usage.
- Each command calls the daemon's [HTTP API](/reference/http-api/) with the admin token in `cli_token`.
  Set `WARDRIK_URL` and `WARDRIK_TOKEN` to use another daemon.
- Use `--json` to request JSON output from commands.
- `AGENT` is a name: `triage` in the deployment's org, or `growth/triage` in another org.
- Commands on an agent take `--conversation ID` to select a conversation.
- Shortcuts: `ls`, `ask` and `follow` for `agent ls`, `agent ask` and `agent follow`.
- In an interactive terminal, commands identify pending approvals and show the approval command:
  `1 call waits on you: wardrik approval approve triage call_1`.

## Set up

| Command | Does |
| --- | --- |
| `init [--org ORG] [--provider P] [--model M] [--key-from-env VAR] [--yes] [--no-service] [--no-ask] [--set KEY=VALUE] [--answers FILE]` | sets up the config, model, key and service, then offers what it finds, such as Claude Code; never overwrites a file |
| `doctor` | validates the daemon's config and connections, whether or not it's running |
| `version` | prints the version |
| `completion SHELL` | prints completion for `bash`, `zsh` or `fish` |

```sh
wardrik init --provider anthropic --model anthropic:claude-sonnet-5 --key-from-env ANTHROPIC_API_KEY --yes
wardrik completion fish > ~/.config/fish/completions/wardrik.fish
```

## Agents

| Command | Does |
| --- | --- |
| `agent ls [QUERY] [--all]` | lists agents and their status; `--all` includes conversations |
| `agent show AGENT` | shows an agent's definition and current activity |
| `agent ask AGENT [MESSAGE] [--no-wait]` | sends a message and streams the reply; `--no-wait` only sends; with no `MESSAGE`, opens `$VISUAL` or `$EDITOR` |
| `agent follow AGENT` | streams an agent's events until Ctrl-C; `--json` prints each event |
| `agent history AGENT` | prints the conversation |
| `agent clear AGENT` | clears the conversation |
| `agent start AGENT` | starts a stopped agent's process |
| `agent stop AGENT` | stops the process until the next message |
| `agent cancel AGENT... [--all]` | stops the current turn and drops queued messages |
| `agent rm AGENT` | removes an agent and its data; doesn't remove file-defined agents |
| `agent calls AGENT` | lists running tool calls |
| `agent kill AGENT CALL` | stops one tool call |
| `agent move AGENT NODE` | restarts it on another node |

In an interactive terminal, `ask` and `follow` display pending calls and prompt for approval.
Press Enter to leave a call pending. The status line shows the agent’s current activity.

A `QUERY` is space-separated terms, all of which must match: text in the name or ID, `name:`,
`org:`, `user:` (as `user:acme/@jon`), `node:`, `status:idle|running|parked|asleep`, or
`attention` (pending approval).

```sh
wardrik ls status:parked
wardrik ask triage "What's on fire?" --conversation C1
wardrik agent follow triage --json
wardrik agent kill triage toolu_01
```

## Approvals

| Command | Does |
| --- | --- |
| `approval` | prompts for each pending call in an interactive terminal; otherwise lists pending calls |
| `approval ls` | lists calls pending approval, with their conversation |
| `approval approve AGENT CALL [--note NOTE]` | runs the call; the model receives the note |
| `approval deny AGENT CALL [--reason REASON]` | denies the call; the model receives the reason |

```sh
wardrik approval deny triage toolu_01 --reason "Not this quarter." --conversation C1
```

## Triggers

| Command | Does |
| --- | --- |
| `trigger ls AGENT` | lists triggers and their next run |
| `trigger set AGENT NAME [--every E] [--timezone TZ] [--prompt P \| --prompt-file F] [--feed URL] [--overlap skip\|queue\|settle]` | sets a trigger |
| `trigger rm AGENT NAME` | removes a trigger |

```sh
wardrik trigger set triage standup --every "0 9 * * 1-5" --timezone Europe/Berlin --prompt "Summarise yesterday."
```

For a file-defined agent, the next reload resets triggers to those in the file.

## Files

| Command | Does |
| --- | --- |
| `agent files ls AGENT [GLOB]` | lists the agent's files, newest first |
| `agent files cat AGENT PATH` | prints a file |
| `agent files put AGENT PATH [FILE]` | writes a file from `FILE`, or from stdin without one or with `-` |
| `agent files rm AGENT PATH` | deletes a file |
| `agent files sync AGENT DIR [--to PREFIX] [--delete]` | writes each file in `DIR` whose content differs |

```sh
wardrik agent files sync triage ./skills --to skills --delete
```

- `sync` leaves out files and directories whose names start with `.`, and files that aren't text.
- `--delete` deletes the agent's files under `PREFIX` that `DIR` doesn't have. Without it, `sync`
  only writes.
- Files written this way have no labels. See [Files and memory](/concepts/files-and-memory/).

## MCP servers, notify targets and OAuth apps

These apply to the deployment's org, or to `--org ORG` or `--user USER`.

| Command | Does |
| --- | --- |
| `server ls` | lists MCP servers added for the owner's agents |
| `server add NAME --url URL [--secret NAME \| --oauth [--scope S]] [--only TOOLS]` | adds an MCP server; agents reference it as `NAME/*` |
| `server rm NAME` | removes one |
| `notify ls` | lists notice webhooks and rooms |
| `notify add NAME --url URL [--secret NAME]` | adds a webhook; agents use it with `notify: NAME` |
| `notify rm NAME` | removes one |
| `provider ls` | lists OAuth apps |
| `provider add NAME [--issuer U \| --resource U \| --authorization-endpoint U --token-endpoint U] --client-id ID [--secret NAME] [--scope S] [--flow device]` | adds an OAuth app |
| `provider rm NAME` | removes one |

`--secret` is the name of a vault secret, stored with the matching [`--for`](#vault).

```sh
wardrik server add crm --url https://mcp.crm.example/mcp --secret CRM_KEY --org acme
wardrik notify add ops --url https://hooks.acme.example/wardrik --secret OPS_HOOK_SECRET --org acme
wardrik provider add github --issuer https://github.com/login/oauth --client-id Iv1.abc --secret GITHUB_CLIENT_SECRET --flow device
```

## Connections

Your own OAuth accounts, used by your agents.

| Command | Does |
| --- | --- |
| `connection ls` | lists providers, your connections, and sign-ins in progress |
| `connection connect PROVIDER` | starts a sign-in; exits when a device sign-in is granted, declined or expired |
| `connection pair PROVIDER CODE` | completes a browser sign-in with the code from its page |
| `connection disconnect PROVIDER` | deletes the connection |

```sh
wardrik connection connect github
wardrik connection pair linear BCDF-GHJK
```

## Vault

| Command | Does |
| --- | --- |
| `vault put NAME [--for PURPOSE]` | stores a secret from a hidden terminal prompt or stdin |
| `vault ls` | lists secret names, never values |
| `vault rm NAME` | removes a secret |

- These apply to the deployment, or to `--org ORG` or `--user USER`.
- `--for` is `api_key`, `client_secret`, `header` or `signing_secret`. A secret is only used for its purpose.
- `${NAME}` in `config.yaml` resolves the deployment's secrets.

```sh
echo "$ANTHROPIC_API_KEY" | wardrik vault put ANTHROPIC_API_KEY --for api_key --org acme
```

## Tokens

| Command | Does |
| --- | --- |
| `token create NAME --subject SUBJECT [--groups G,H] [--expires 30d]` | creates a token; prints the secret once |
| `token ls` | lists tokens, never their secrets |
| `token revoke ID` | revokes a token immediately |

- `--subject` is a user, as `user:acme/@ana`, or an agent, as `agent:triage` or
  `agent:growth/triage`.
- `--groups` sets groups for [bindings](/reference/config/#roles-and-bindings) to match.
- `--expires` takes `s`, `m`, `h` or `d`; default `30d`.
- Requires a binding on `token` in `"*"`. Only the admin can create a `user:admin` token.

```sh
wardrik token create ana-laptop --subject user:acme/@ana --groups payments-eng --expires 30d
wardrik token revoke mzxw6ytboi
```

## Daemon

| Command | Does |
| --- | --- |
| `serve` | runs the daemon in the foreground, logging to the terminal |
| `start` | starts it in the background |
| `stop` | stops it |
| `pid` | prints its process ID |
| `logs` | tails its logs |
| `service install` | installs the systemd user service |
| `service uninstall` | removes the systemd user service |
| `status` | prints the URL, and the agent count per node |
| `web` | prints a link that signs you in to the [dashboard](/run/dashboard/); it works for two minutes |
| `reload [AGENT...]` | rereads agent files on every node |
| `audit` | prints the audit log, oldest first |
| `uninstall [--purge] [--yes]` | stops the daemon and removes what install.sh installed; keeps the config, keys and store unless `--purge` |

```sh
wardrik service install
wardrik reload triage
```
