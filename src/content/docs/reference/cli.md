---
title: "CLI"
description: "Every command wardrik takes, and what each does."
editUrl: false
sidebar:
  order: 1
---

Every command `wardrik` takes. `rik` is the same command, shorter: `rik ls` is `wardrik ls`.

```sh
wardrik agent ls
wardrik ask triage "What's new?"
wardrik approval approve triage toolu_01 --note "Only this once."
```

`wardrik help` lists every command. `wardrik help COMMAND`, or `COMMAND --help`, says more about
one.

## How commands work

- Each command runs an operation on the daemon over its [HTTP API](/reference/http-api/). It acts
  with the owner token the daemon writes to `cli_token` in the data home each time it starts.
- `serve`, `start`, `stop`, `pid`, `logs` and `service` run the daemon itself, so the `wardrik`
  script handles them without the API.
- Every command takes `--json`, and then prints the operation's JSON answer.
- An option a command doesn't take is refused.
- An agent is named by its ID, as `acme/triage` or `acme/@jon/notes`, or without the deployment's
  org, as `triage` or `@jon/notes`. The deployment's org is `config.yaml`'s
  [`org`](/reference/config/#org).

| Variable | Means |
| --- | --- |
| `WARDRIK_URL`, `WARDRIK_TOKEN` | reach another daemon with this URL and token; both must be set |
| `WARDRIK_CONFIG_DIR`, `WARDRIK_DATA_HOME`, `WARDRIK_STATE_DIR`, `WARDRIK_ENV_FILE` | move the directories; see [Directories](/reference/config/#directories) |

## Shortcuts

| Shortcut | Command |
| --- | --- |
| `wardrik ls` | `wardrik agent ls` |
| `wardrik ask` | `wardrik agent ask` |
| `wardrik follow` | `wardrik agent follow` |

## Set up

### wardrik init

Set up the front door, its model and key, and the daemon to run it. It asks what it needs, says
what it does, and keeps any file that's already there.

```sh
wardrik init [--org ORG] [--provider PROVIDER] [--model MODEL] [--key-from-env VAR] [--yes] \
  [--no-service] [--no-ask]
```

| Option | Means |
| --- | --- |
| `--org ORG` | the deployment's org; `default` unless set |
| `--provider PROVIDER` | the model provider, as `anthropic`; asked at a terminal, and needed without one |
| `--model MODEL` | the provider's model, as `claude-sonnet-5`; `claude-haiku-4-5` for Anthropic unless set, or else the provider's newest |
| `--key-from-env VAR` | the provider's key, from the variable `VAR` |
| `--yes` | run the daemon as a systemd user service, where there's no terminal to ask |
| `--no-service` | start the daemon with `wardrik start`, not systemd |
| `--no-ask` | don't ask the front door anything |

In order, it:

1. says which model providers' keys the environment sets.
2. asks for the provider, those with a key here first, and the model.
3. reads the provider's key without showing it, unless the env file or the environment sets it.
   Without a terminal, `--key-from-env` or the environment gives it.
4. writes three files in the config directory, keeping any already there.
5. starts the daemon: as a systemd user service where there's one and you say so, or else with
   `wardrik start`. A daemon already running reads the new front door's file.
6. seals the key in the vault as the deployment's secret, unless the env file sets it.
7. asks the front door one short question.

| File | Holds |
| --- | --- |
| `config.yaml` | the org, the default model, and `http.port: 4747` |
| `agents/assistant.md` | the front door; see [The front door](/build/front-door/) |
| `env` | commented lines for `ANTHROPIC_API_KEY` and `BRAVE_API_KEY`; only you can read it |

The front door has `web_search` where `BRAVE_API_KEY` is set. Elsewhere `config.yaml` says how to
turn it on.

### wardrik doctor

Check what the daemon reads, running or not.

```sh
wardrik doctor
```

It prints a line for each check: the env file, `config.yaml`, the store, the vault, each MCP
server, each channel, and the agent and policy files. It exits with `1` if any check fails.

### wardrik version

Print the version.

```sh
wardrik version
#=> wardrik 0.1.0-rc.1
```

### wardrik completion

Completion for bash, zsh or fish, to install.

```sh
wardrik completion SHELL
```

It completes commands and their options, for `wardrik` and `rik`:

```sh
wardrik completion bash > ~/.local/share/bash-completion/completions/wardrik
wardrik completion zsh > "${fpath[1]}/_wardrik"
wardrik completion fish > ~/.config/fish/completions/wardrik.fish
```

## Agents

### wardrik agent ls

List the agents, and what each is doing.

```sh
wardrik agent ls [QUERY] [--all]
```

It shows each agent's status, queued messages, next trigger run, and what it spent today. An
agent's conversations, such as a Slack thread's, are counted under it; `--all` lists them too.

A QUERY is words that must all match:

| Word | Matches |
| --- | --- |
| any text | agents whose ID holds it |
| `name:NAME` | agents of that name |
| `org:ORG` | agents of that org |
| `user:USER` | agents that work for that user, as `user:jon` |
| `node:NODE` | agents running on that node |
| `status:STATUS` | `idle`, `running`, `parked` or `asleep` |
| `attention` | agents waiting on a person |

### wardrik agent show

What an agent is, and what it does now.

```sh
wardrik agent show AGENT
```

It shows the agent's status, description, model, tools, policy, triggers and channels, the
tools it names that offer nothing yet, and the calls it waits on a person for.

### wardrik agent ask

Send an agent a message, and follow its answer.

```sh
wardrik agent ask AGENT MESSAGE [--no-wait]
```

It shows the agent's reasoning faintly as it comes, then its answer, with each tool call it makes.
It follows the turn until the turn ends or waits on a person.

- Ctrl-C stops following. The agent carries on.
- `--no-wait` only sends the message.

### wardrik agent follow

Follow what an agent does, until Ctrl-C.

```sh
wardrik agent follow AGENT
```

With `--json`, it prints each [event](/reference/events/) as the HTTP API streams it, a line each.

### wardrik agent history

An agent's conversation.

```sh
wardrik agent history AGENT
```

### wardrik agent clear

Empty an agent's conversation.

```sh
wardrik agent clear AGENT
```

It also clears the labels of what the agent read, such as `outside`. It's refused while the agent
runs a turn or waits on a person.

### wardrik agent start

Start an agent that sleeps.

```sh
wardrik agent start AGENT
```

### wardrik agent stop

Stop an agent until something wakes it.

```sh
wardrik agent stop AGENT
```

It keeps its conversation. A message, a trigger or `wardrik agent start` wakes it.

### wardrik agent cancel

Stop the turn an agent runs or waits in.

```sh
wardrik agent cancel AGENT|PATTERN [--all]
```

- The messages waiting behind the turn go too.
- A PATTERN, as `acme/agent/*`, stops the turns of every agent it covers.
- `--all`, given alone, stops the turns of every agent there is.

### wardrik agent rm

Remove an agent, and everything it had.

```sh
wardrik agent rm AGENT
```

It removes the agent's conversation, definition and triggers. An agent a file declares stays:
remove its file, then run `wardrik reload`.

### wardrik agent calls

The tool calls an agent is running now, and how long each has run.

```sh
wardrik agent calls AGENT
```

### wardrik agent kill

Stop one tool call an agent is running.

```sh
wardrik agent kill AGENT CALL
```

The model is answered with an error, as if the tool had failed, and the turn goes on.
`wardrik agent calls` lists the calls. `wardrik agent cancel` ends the whole turn instead.

### wardrik agent move

Start an agent again on another node of the cluster, with its conversation.

```sh
wardrik agent move AGENT NODE
```

A turn it's taking ends, and what it waits on a person for is abandoned.

## Approvals

### wardrik approval ls

The calls agents wait on a person for.

```sh
wardrik approval ls
```

A call held because its run read content from outside says so.

### wardrik approval approve

Let a call run.

```sh
wardrik approval approve AGENT CALL [--note NOTE]
```

`--note` reaches the model beside the call's result. The call runs as the model wrote it.

### wardrik approval deny

Refuse a call.

```sh
wardrik approval deny AGENT CALL [--reason REASON]
```

`--reason` reaches the model as the call's error.

## Triggers

### wardrik trigger ls

An agent's triggers, and when each runs next.

```sh
wardrik trigger ls AGENT
```

### wardrik trigger set

Set one of an agent's triggers.

```sh
wardrik trigger set AGENT NAME [--every EVERY] [--timezone TIMEZONE] [--prompt PROMPT] \
  [--prompt-file FILE] [--feed URL] [--overlap OVERLAP]
```

| Option | Means |
| --- | --- |
| `--every` | a cron expression, as `"0 9 * * 1-5"`, or an interval, as `30m` |
| `--timezone` | the time zone a cron expression is read in, as `Europe/Berlin` |
| `--prompt` | what the trigger asks |
| `--prompt-file` | a file of the agent's to read and follow, in place of `--prompt` |
| `--feed` | an RSS or Atom feed to watch |
| `--overlap` | `skip` or `queue` |

An agent a file declares takes its file's triggers again on the next reload. See
[triggers](/reference/agent-files/#triggers) for each key.

### wardrik trigger rm

Remove one of an agent's triggers.

```sh
wardrik trigger rm AGENT NAME
```

## MCP servers

These act for the deployment's org, unless given `--org ORG`, or `--user USER` for a user of the
deployment's org.

### wardrik server ls

The MCP servers an owner added for their agents.

```sh
wardrik server ls [--org ORG] [--user USER]
```

### wardrik server add

Add an MCP server for an owner's agents.

```sh
wardrik server add NAME --url URL [--secret NAME | --oauth [--scope SCOPE]...] [--only TOOLS] \
  [--org ORG] [--user USER]
```

| Option | Means |
| --- | --- |
| `--url` | required. The server's full `https` endpoint, as `https://mcp.linear.app/mcp`, reached over Streamable HTTP as given |
| `--secret NAME` | sign in with the owner's secret of that name from the vault |
| `--oauth` | sign in in a browser |
| `--scope` | a scope `--oauth` asks for; give it once for each |
| `--only` | the server's tools to take, by name, with commas |

Without `--secret` or `--oauth`, agents reach it with no credential. Agents name its tools as
`NAME/*` in their [`tools`](/reference/agent-files/#tools).

### wardrik server rm

Remove an MCP server an owner added.

```sh
wardrik server rm NAME [--org ORG] [--user USER]
```

## Connections

These act for the deployment's org, unless given `--org ORG` or `--user USER`.

### wardrik connection ls

The accounts an owner is offered, and which they hold.

```sh
wardrik connection ls [--org ORG] [--user USER]
```

### wardrik connection connect

Sign an owner in to an account, for their agents to use.

```sh
wardrik connection connect PROVIDER [--org ORG] [--user USER]
```

It prints the link to sign in at, or says the account is connected already.

### wardrik connection disconnect

Forget an owner's account.

```sh
wardrik connection disconnect PROVIDER [--org ORG] [--user USER]
```

## Tokens

### wardrik token create

Make a token for the HTTP API, and show its secret once.

```sh
wardrik token create NAME --resource PATTERN... --role ROLES [--expires DURATION] [--policy NAME]
```

| Option | Means |
| --- | --- |
| `--resource` | what it reaches, as `acme/*`; give it once for each pattern |
| `--role` | a role, or several with commas: `reader`, `messenger`, `approver`, `definer`, `worker` or `owner` |
| `--expires` | how long it lasts, as `30d`, `12h`, `15m` or `45s`; 90 days unless set |
| `--policy` | a policy in `policies/` every agent it defines is held to |

A token acts for whoever made it, and is no wider than its maker. See [Tokens](/reference/http-api/#tokens)
for resource patterns and roles.

```sh
wardrik token create ci --resource 'acme/agent/*' --role reader,messenger --expires 30d
```

### wardrik token ls

The tokens, and when each expires.

```sh
wardrik token ls
```

### wardrik token revoke

Stop a token working.

```sh
wardrik token revoke ID
```

## Vault

These act for the deployment, unless given `--org ORG` or `--user USER`.

### wardrik vault put

Seal a secret, reading its value from standard input.

```sh
echo "$VALUE" | wardrik vault put NAME [--org ORG] [--user USER]
```

| Owner | Who reads it |
| --- | --- |
| the deployment | `${NAME}` in `config.yaml`, and model providers' keys; no agent's call |
| `--org ORG` | the org's agents |
| `--user USER` | the user's agents, in the deployment's org |

### wardrik vault ls

The names of the secrets held, never their values.

```sh
wardrik vault ls [--org ORG] [--user USER]
```

### wardrik vault rm

Remove a secret.

```sh
wardrik vault rm NAME [--org ORG] [--user USER]
```

## Daemon

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

Stop the daemon.

```sh
wardrik stop
```

### wardrik pid

The daemon's process id.

```sh
wardrik pid
```

### wardrik logs

Follow what the daemon logs, from its last 100 lines.

```sh
wardrik logs
```

### wardrik service install

Run the daemon as a systemd user service, `wardrik`.

```sh
wardrik service install
```

It writes `~/.config/systemd/user/wardrik.service`, then enables and starts it.

### wardrik service uninstall

Stop running the daemon as a service, and remove its unit.

```sh
wardrik service uninstall
```

### wardrik status

Where the daemon runs, and how many agents each node holds.

```sh
wardrik status
```

It also counts the agents asleep. With `--json`, the answer of
[`GET /v1/deployment/nodes`](/reference/http-api/#routes).

### wardrik reload

Read the agent files again, on every node.

```sh
wardrik reload [PATTERN...]
```

Each PATTERN, as `acme/agent/*`, narrows the agents brought to their definitions to those it
covers. It prints what didn't read. `config.yaml` and `policies/` are read only as the daemon
starts, so restart it after changing them.

### wardrik audit

What people changed, oldest first.

```sh
wardrik audit
```

It shows when, what, who and on what for each change. With `--json`, the answer of
[`GET /v1/deployment/audit`](/reference/http-api/#routes).
