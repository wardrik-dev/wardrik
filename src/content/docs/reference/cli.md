---
title: "CLI"
description: "Every command wardrik takes, with an example each."
sidebar:
  order: 1
---

```sh
wardrik agent ls
wardrik ask triage "What's new?"
wardrik approval approve triage toolu_01 --note "Only this once."
```

- `rik` is the same command: `rik ls` is `wardrik ls`.
- `wardrik help COMMAND`, or `COMMAND --help`, says more about one.
- Each command calls the daemon's [HTTP API](/reference/http-api/) with the admin token in `cli_token`.
  Set `WARDRIK_URL` and `WARDRIK_TOKEN` to reach another daemon.
- Every command takes `--json` and prints the API's JSON.
- An agent is a name: `triage` in the deployment's org, or `growth/triage` in another.
- Commands on one agent take `--conversation ID` to act on one conversation.
- Shortcuts: `ls`, `ask` and `follow` for `agent ls`, `agent ask` and `agent follow`.

## Set up

| Command | Does |
| --- | --- |
| `init [--org ORG] [--provider P] [--model M] [--key-from-env VAR] [--yes] [--no-service] [--no-ask]` | sets up the config, model, key and service; never overwrites a file |
| `doctor` | checks what the daemon reads, running or not |
| `version` | prints the version |
| `completion SHELL` | prints completion for `bash`, `zsh` or `fish` |

```sh
wardrik init --provider anthropic --model anthropic:claude-sonnet-5 --key-from-env ANTHROPIC_API_KEY --yes
wardrik completion fish > ~/.config/fish/completions/wardrik.fish
```

## Agents

| Command | Does |
| --- | --- |
| `agent ls [QUERY] [--all]` | lists agents and what each is doing; `--all` lists conversations too |
| `agent show AGENT` | shows an agent and what it does now |
| `agent ask AGENT MESSAGE [--no-wait]` | sends a message and follows the answer; `--no-wait` only sends |
| `agent follow AGENT` | follows what an agent does, until Ctrl-C; `--json` prints each event |
| `agent history AGENT` | prints its conversation |
| `agent clear AGENT` | empties its conversation |
| `agent start AGENT` | starts a sleeping agent |
| `agent stop AGENT` | stops it until something wakes it |
| `agent cancel AGENT... [--all]` | stops the current turn and drops queued messages |
| `agent rm AGENT` | removes an agent and everything it had; one an agent file declares stays |
| `agent calls AGENT` | lists the tool calls it's running |
| `agent kill AGENT CALL` | stops one tool call |
| `agent move AGENT NODE` | restarts it on another node |

A `QUERY` is words that must all match: text in the name or ID, `name:`, `org:`, `user:` (as
`user:acme/@jon`), `node:`, `status:idle|running|parked|asleep`, or `attention` (waiting on a person).

```sh
wardrik ls status:parked
wardrik ask triage "What's on fire?" --conversation C1
wardrik agent follow triage --json
wardrik agent kill triage toolu_01
```

## Approvals

| Command | Does |
| --- | --- |
| `approval ls` | lists the calls agents wait on a person for, with their conversation |
| `approval approve AGENT CALL [--note NOTE]` | lets the call run; the note reaches the model |
| `approval deny AGENT CALL [--reason REASON]` | refuses the call; the reason reaches the model |

```sh
wardrik approval deny triage toolu_01 --reason "Not this quarter." --conversation C1
```

## Triggers

| Command | Does |
| --- | --- |
| `trigger ls AGENT` | lists its triggers and when each runs |
| `trigger set AGENT NAME [--every E] [--timezone TZ] [--prompt P \| --prompt-file F] [--feed URL] [--overlap skip\|queue]` | sets a trigger |
| `trigger rm AGENT NAME` | removes a trigger |

```sh
wardrik trigger set triage standup --every "0 9 * * 1-5" --timezone Europe/Berlin --prompt "Summarise yesterday."
```

An agent file's triggers come back on the next reload.

## MCP servers, notify targets and OAuth apps

These act for the deployment's org, or `--org ORG` or `--user USER`.

| Command | Does |
| --- | --- |
| `server ls` | lists MCP servers added for the owner's agents |
| `server add NAME --url URL [--secret NAME \| --oauth [--scope S]] [--only TOOLS]` | adds an MCP server; agents name it `NAME/*` |
| `server rm NAME` | removes one |
| `notify ls` | lists the webhooks and rooms notices reach |
| `notify add NAME --url URL [--secret NAME]` | adds a webhook; agents route to it with `notify: NAME` |
| `notify rm NAME` | removes one |
| `provider ls` | lists the OAuth apps people sign in with |
| `provider add NAME [--issuer U \| --resource U \| --authorization-endpoint U --token-endpoint U] --client-id ID [--secret NAME] [--scope S] [--flow device]` | adds an OAuth app |
| `provider rm NAME` | removes one |

`--secret` names a vault secret, sealed with the matching [`--for`](#vault).

```sh
wardrik server add crm --url https://mcp.crm.example/mcp --secret CRM_KEY --org acme
wardrik notify add ops --url https://hooks.acme.example/wardrik --secret OPS_HOOK_SECRET --org acme
wardrik provider add github --issuer https://github.com/login/oauth --client-id Iv1.abc --secret GITHUB_CLIENT_SECRET --flow device
```

## Connections

Your own accounts, for your agents to use.

| Command | Does |
| --- | --- |
| `connection ls` | lists the accounts you can connect, which you hold, and sign-ins under way |
| `connection connect PROVIDER` | signs you in; waits until a device sign-in is granted, declined or expired |
| `connection pair PROVIDER CODE` | finishes a browser sign-in with the code its page showed |
| `connection disconnect PROVIDER` | forgets your account |

```sh
wardrik connection connect github
wardrik connection pair linear BCDF-GHJK
```

## Vault

| Command | Does |
| --- | --- |
| `vault put NAME [--for PURPOSE]` | seals a secret read from stdin |
| `vault ls` | lists secret names, never values |
| `vault rm NAME` | removes a secret |

- They act for the deployment, or `--org ORG` or `--user USER`.
- `--for` is `api_key`, `client_secret`, `header` or `signing_secret`. A secret is only read for that.
- `${NAME}` in `config.yaml` reads the deployment's secrets.

```sh
echo "$ANTHROPIC_API_KEY" | wardrik vault put ANTHROPIC_API_KEY --for api_key --org acme
```

## Tokens

| Command | Does |
| --- | --- |
| `token create NAME --subject SUBJECT [--groups G,H] [--expires 30d]` | makes a token, shown once |
| `token ls` | lists tokens, never their secrets |
| `token revoke ID` | stops a token at once |

- `--subject` is a person, as `user:acme/@ana`, or `agent:NAME` for an agent's own, as
  `agent:triage` or `agent:growth/triage`.
- `--groups` are the groups [bindings](/reference/config/#roles-and-bindings) can name.
- `--expires` takes `s`, `m`, `h` or `d`; `30d` unless set.
- It needs a binding on `token` in `"*"`. Only the admin makes a `user:admin` token.

```sh
wardrik token create ana-laptop --subject user:acme/@ana --groups payments-eng --expires 30d
wardrik token revoke mzxw6ytboi
```

## Daemon

| Command | Does |
| --- | --- |
| `serve` | runs the daemon here, logging to the terminal |
| `start` | runs it in the background |
| `stop` | stops it |
| `pid` | prints its process ID |
| `logs` | follows its logs |
| `service install` | runs it as a systemd user service |
| `service uninstall` | stops running it as a service |
| `status` | where it runs, and how many agents each node holds |
| `reload [AGENT...]` | reads the agent files again on every node |
| `audit` | prints what people changed, oldest first |

```sh
wardrik service install
wardrik reload triage
```
