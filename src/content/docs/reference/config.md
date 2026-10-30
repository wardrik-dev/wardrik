---
title: "config.yaml"
description: "What the daemon reads as it starts: the deployment's orgs and address, the MCP servers and channels agents reach, where secrets and the store are kept, and the defaults agents are given."
sidebar:
  order: 2
---

What the daemon reads as it starts: the deployment's orgs and address, the MCP servers and channels
agents reach, where secrets and the store are kept, and the defaults agents are given.

```yaml
# ~/.config/wardrik/config.yaml
org: acme
base_url: https://agents.acme.example

defaults:
  model: anthropic:claude-sonnet-5
  tools: [web_search]
  policy: careful
  retries: {attempts: 3, on_exhausted: fail}

mcp:
  linear:
    url: https://mcp.linear.app/mcp
    headers:
      authorization: Bearer ${LINEAR_TOKEN}
  notes:
    command: npx
    args: [-y, "@modelcontextprotocol/server-filesystem", /srv/notes]
    only: [read_file, list_directory]

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    approvers: ["@maria"]

notify:
  ops:
    channel: slack
    room: "#ops"
    approvers: ["@maria"]
```

- The file is `config.yaml` in the config directory. Without it, every key takes its default.
- The daemon reads it as it starts, so restart the daemon after a change.
- A key it doesn't know, a value of the wrong shape, or a `${NAME}` nothing sets stops the daemon,
  and it says where. `wardrik doctor` checks the file without starting anything.

## Secrets

`${NAME}` in any string is replaced with, in order:

1. the environment variable `NAME`, or one the [env file](#directories) sets;
2. the deployment's secret `NAME` in the vault, which `echo "$VALUE" | wardrik vault put NAME`
   seals.

So the file holds no secret. `vault`, `http` and `storage` are read before the vault opens, so
they take the environment and env file alone.

## Keys

| Key | What it configures |
| --- | --- |
| [`org`](#org) | the deployment's org |
| [`orgs`](#orgs) | the other orgs, what each uses, and the policy each is held to |
| [`base_url`](#base_url) | the address people and services reach the daemon at |
| [`defaults`](#defaults) | what an agent is given where its definition says nothing |
| [`models`](#models) | prices for models the catalog lacks |
| [`mcp`](#mcp) | MCP servers whose tools agents may call |
| [`oauth`](#oauth) | providers people connect accounts with |
| [`channels`](#channels) | chat apps agents are reached through, such as Slack |
| [`notify`](#notify) | where agents' notices go |
| [`workspace`](#workspace) | the trees of files agents beyond their owners may share |
| [`brave`](#brave) | the key web search searches with |
| [`vault`](#vault) | the vault's keys |
| [`http`](#http) | where the HTTP API listens |
| [`storage`](#storage) | the store everything is kept in |

`tools`, `tokens`, `cluster` and `ssh` are [not read yet](#keys-not-read-yet).

## org

The deployment's org. `default` unless set.

- An agent file belongs to it. A file that names another `org` doesn't read.
- The CLI finds an agent named without an org in it.

## orgs

The orgs beside the deployment's own, each with the servers, channels and notify targets its agents
use, and the policy they are held to. Each server, channel and target is defined once, under `mcp`,
`channels` or `notify`, and an org lists it by name.

```yaml
org: platform

mcp:
  stripe: {url: https://mcp.stripe.com, credential: STRIPE_AGENT_KEY}
  github: {url: https://api.githubcopilot.com/mcp/, credential: GITHUB_TOKEN}
  search: {url: https://search.example.com/mcp, credential: SEARCH_API_KEY}

channels:
  payments-slack: {type: slack, token: "${PAYMENTS_SLACK_BOT_TOKEN}", signing_secret: "${PAYMENTS_SLACK_SIGNING_SECRET}"}
  growth-slack: {type: slack, token: "${GROWTH_SLACK_BOT_TOKEN}", signing_secret: "${GROWTH_SLACK_SIGNING_SECRET}"}

orgs:
  "*":
    mcp: [search]
    policy: base
  payments:
    mcp: [stripe, github]
    channels: [payments-slack]
    policy: payments-strict
  growth:
    mcp: [github]
    channels: [growth-slack]
```

| Key | Means |
| --- | --- |
| `mcp` | the servers of `mcp` the org's agents use, by name |
| `channels` | the channels of `channels` that serve the org's agents, by name |
| `notify` | the targets of `notify` that tell the org's agents, by name |
| `policy` | a policy in `policies/` every agent of the org is held to |

- An org's name is letters, digits, `_`, `.` and `-`. `deployment` is taken. An entry may be
  empty: `growth: {}`.
- `"*"` is every org. What it lists, every org uses, and its `policy` holds every org beside the
  org's own.
- A server, channel or target no entry lists is the deployment's own org's.
- A channel serves one org, or every org where `"*"` lists it. Two orgs listing one channel is an
  error.
- `policy` holds every agent of the org, ahead of its own, however it was defined. A definition can
  narrow it, never widen it. An org whose policy `policies/` doesn't hold runs none of its agents.
- A policy's budget is the org's: all of its agents spend from it together. Each org spends `"*"`'s
  budget apart from the others. A budget `per: turn` stays each agent's own.
- An agent, secret or token in an org that is neither `org` nor in `orgs` is refused.

Each org's agents reach a server with their org's own credential, so payments and growth each seal a
`GITHUB_TOKEN` of their own. See [Credentials](#credentials).

## base_url

Where people and services reach the deployment, through whatever is in front of the daemon. The
HTTP API's own URL unless set.

- Webhook triggers are sent requests under it, at `/v1/hooks/`.
- A provider sends a browser back to `{base_url}/oauth` after a sign-in.

## defaults

What every agent is given where its definition says nothing. It takes the keys an
[agent file](/reference/agent-files/) does, such as `model`, `tools` and `policy`. It holds agent
files and definitions sent over the HTTP API alike. `wardrik init` writes `model`.

Where neither the definition nor `defaults` sets them:

| Key | Default |
| --- | --- |
| `idle_timeout` | `900` seconds |
| `max_iterations` | `25` |
| `timeout` | none |
| [`retries`](/reference/agent-files/#retries) | `attempts: 6`, `max_wait: 60`, `on_exhausted: ask` |

## models

Prices for models the catalog lacks, by model spec, in US dollars per million tokens. A budget in
dollars counts them.

```yaml
models:
  zai:glm-5.1:
    input: 0.60
    output: 2.20
  zai_coding_plan:glm-5.1:
    priced_as: zai:glm-5.1
    markup: 0.1
```

| Key | Means |
| --- | --- |
| `input`, `output` | dollars per million input and output tokens |
| `cache_read`, `cache_write` | dollars per million cached tokens read and written |
| `priced_as` | another model whose price this one takes, in place of the rates |
| `markup` | a share added to the price, as `0.1` for 10% |

## mcp

MCP servers, each by a name of your own, which is how agents and policies name its tools:
`linear/*`. A server is run as a command, with `command`, or reached over HTTP, with `url`; not
both.

```yaml
mcp:
  notes:
    command: npx
    args: [-y, "@modelcontextprotocol/server-filesystem", /srv/notes]
  github:
    url: https://api.githubcopilot.com/mcp/
    credential: github
    gated: [create_*, issue_write]
```

| Key | Means |
| --- | --- |
| `command`, `args`, `env` | the program that runs the server over stdio |
| `url`, `headers` | where the server is reached over Streamable HTTP: its full endpoint, as `https://mcp.linear.app/mcp`, used exactly as given |
| `only`, `except` | the server's tools to offer, or to leave out, by the names it gives them; every tool unless set |
| `prefix` | what its tool names start with; the server's name unless set |
| `timeout` | seconds a call may take; `60` unless set |
| `max_result_bytes` | how much of a call's answer reaches the model; `131072` unless set |
| `gated` | the tools whose calls wait on a person unless a rule allows them by name, as `[create_*]`; `true` or `false` for all or none; every tool the server doesn't mark read-only unless set |
| `trusted` | `true` where the server's answers are the deployment's own, so they aren't labelled `outside`; `false` unless set |
| `credential` | the name of the credential each owner reaches the server with |
| `credential_header`, `credential_scheme` | the header a credential is sent in, and its scheme; `authorization` and `Bearer` unless set |
| `credential_env` | the variable a credential is given to a command in |

A server serves the orgs that [`orgs`](#orgs) lists it for. `cwd` isn't supported yet. See
[Connect MCP servers](/build/mcp/).

### Credentials

A credential is sealed in the vault, and found for each call as the agent's owner holds it:

- an agent that works for a user takes the user's (`wardrik vault put NAME --user USER`);
- any other agent takes its org's (`--org ORG`).

One owner never reads another's. The deployment's own secrets (`wardrik vault put NAME`) and the
daemon's environment reach no agent: they are for model providers' keys and `${NAME}` in this file.
Where the owner holds none and `oauth` has a provider of the same name, the owner is asked to
connect an account. See [Connect accounts](/build/accounts/).

## oauth

`providers` names a provider for each credential people connect, named like the credential.

```yaml
oauth:
  providers:
    github:
      issuer: https://github.com/login/oauth
      client_id: ${GITHUB_CLIENT_ID}
      client_secret: ${GITHUB_CLIENT_SECRET}
      scopes: [repo]
      flow: device
```

| Key | Means |
| --- | --- |
| `issuer` | the authorization server's issuer URL |
| `resource` | the resource the token is for |
| `client_id`, `client_secret` | the OAuth app registered with the provider |
| `authorization_endpoint`, `token_endpoint` | the provider's endpoints, where the issuer publishes no metadata |
| `scopes` | the scopes to ask for |
| `flow` | `browser` or `device` |
| `client_auth` | how the client secret is sent: `post` or `basic` |

A provider sends a browser back to `{base_url}/oauth`, which the HTTP API serves. `oauth.client`
and `oauth.redirect` aren't supported yet. See [A public address](/run/public-address/).

## channels

Chat apps agents are reached through, each by a name of your own: lower-case letters, digits and
`-`, starting with a letter. `shell`, `ssh`, `terminal` and `oauth` are taken.

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
    approvers: ["@maria"]
```

| Key | Means |
| --- | --- |
| `type` | required. The kind of channel: `slack` |
| `token` | the bot's token for the one workspace it reaches; without one, the channel keeps a token in the vault for each workspace it's added to |
| `approvers` | who may decide what agents wait on: `@handle`s, or `anyone`; `[]` unless set |
| `signing_secret` | Slack's signing secret, to take its requests over HTTP at `/v1/channels/NAME/` |
| `app_token` | a Slack app-level token, to take its requests over Socket Mode instead |
| `client_id`, `client_secret`, `redirect_uri` | a Slack app added to many workspaces |

- Everyone in a channel may read and message the agents it serves.
- Its approvers may also decide what those agents wait on. Whoever asked for a turn may decide what
  that turn waits on.
- An agent is offered in a channel's rooms where its definition's
  [`channels`](/reference/agent-files/#channels) lists the channel.
- A channel serves the deployment's own org, unless [`orgs`](#orgs) gives it to another, or to
  every org.
- `admins` and `create` aren't supported yet.

See [Channels](/channels/) and [Slack](/channels/slack/).

## notify

Targets an agent's [`notify`](/reference/agent-files/#notify) sends notices to, each a room of a
channel or a webhook. A target's name can't hold `:`.

```yaml
notify:
  ops:
    channel: slack
    room: "#ops"
    approvers: ["@maria"]
  audit:
    webhook:
      url: https://hooks.example.com/wardrik
      secret: ${WARDRIK_WEBHOOK_SECRET}
```

| Target | Keys |
| --- | --- |
| a room | `channel`, one of `channels`; `room`; and optional `approvers`, who may answer it |
| a webhook | `webhook`, with `url` and an optional `secret` |

A target tells the deployment's own org's agents, unless [`orgs`](#orgs) lists it for others. An
agent's `notify` may also name a room of a channel itself, as `slack:#updates`, with no target
here. See [Send notices](/build/notices/).

## workspace

`shared` names the trees agents beyond their owners may mount, each with the agents, by resource
pattern, that may `read` it and those that may `write` it. An agent still names each tree it mounts
in its own [`workspace`](/reference/agent-files/#workspace).

```yaml
org: acme

workspace:
  shared:
    acme/runbooks:
      read: ["acme/*"]                             # every agent in acme, its users' included
      write: [acme/agent/ops, "acme/agent/ops/*"]  # the org's ops agent, in every conversation
```

## brave

`api_key` is the key `web_search` searches with, for every agent the daemon runs.

```yaml
brave:
  api_key: ${BRAVE_API_KEY}
```

`${BRAVE_API_KEY}` reads the environment, else the deployment's secret, which
`wardrik vault put BRAVE_API_KEY` seals. Without `brave`, a search answers that the key is missing.

## vault

`keys` lists the vault's keys. Without them, the key is `WARDRIK_VAULT_KEY`, or else `vault_key` in
the data home, which the daemon makes the first time it starts.

```yaml
vault:
  keys: ["${WARDRIK_VAULT_KEY}"]
```

## http

Where the HTTP API listens. See [HTTP API](/reference/http-api/).

| Key | Means |
| --- | --- |
| `port` | the port; `4747` unless set |
| `ip` | the address to listen on, as `0.0.0.0`; `127.0.0.1` unless set |
| `trusted_workers` | `true` where tool workers' answers are the deployment's own, so they aren't labelled `outside`; `false` unless set |

Beside the API, it serves what each channel's chat app sends under `/v1/channels/`, webhook
triggers under `/v1/hooks/`, and the page a provider sends a browser back to under `/oauth/`. See
[A public address](/run/public-address/).

## storage

The store everything is kept in. Without `storage`, it's on the node's disk under
`WARDRIK_DATA_DIR`.

```yaml
storage:
  postgres:
    url: postgres://wardrik:${PGPASSWORD}@db.internal:5432/wardrik
```

`postgres` takes `url`, a `postgres://` URL. The daemon creates its table as it starts. See
[Storage](/run/storage/).

## Keys not read yet

These keys are passed over with a warning in the log:

| Key | Was for |
| --- | --- |
| `tools` | what one call to a tool costs, for a budget |
| `tokens` | how long tokens last |
| `cluster` | the other daemons this one runs with |
| `ssh` | where the terminal client listens |

### tools

`tools` isn't read yet. A tool call is priced only where the tool reports its own cost.

## Directories

The daemon follows the XDG base directories, so what you write stays apart from what the daemon
writes. Each is moved by its environment variable.

| Variable | Default | Holds |
| --- | --- | --- |
| `WARDRIK_CONFIG_DIR` | `~/.config/wardrik` | `config.yaml`, `agents/` and `policies/` |
| `WARDRIK_DATA_DIR` | `~/.local/share/wardrik/store` | the store, where `storage` isn't set |
| `WARDRIK_DATA_HOME` | `~/.local/share/wardrik` | `vault_key`, `cli_token` and `cookie` |
| `WARDRIK_COOKIE_FILE` | `cookie` in `WARDRIK_DATA_HOME` | the node's Erlang cookie |
| `WARDRIK_STATE_DIR` | `~/.local/state/wardrik` | `log/erlang.log.*`, what `wardrik start` logs |
| `WARDRIK_ENV_FILE` | `env` in `WARDRIK_CONFIG_DIR` | variables the daemon sets where its environment doesn't |

Each default follows `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME` and `$XDG_STATE_HOME` where they are set.

The env file holds one `NAME=value` a line, with an optional `export` and optional quotes. Blank
lines and `#` comments are skipped. The `wardrik` script warns where others can read it.

```sh
# ~/.config/wardrik/env
ANTHROPIC_API_KEY=sk-ant-...
export SLACK_BOT_TOKEN="xoxb-..."
```
