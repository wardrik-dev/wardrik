---
title: "config.yaml"
description: "Every key the wardrik daemon reads from config.yaml."
sidebar:
  order: 2
---

```yaml
# ~/.config/wardrik/config.yaml
org: acme
base_url: https://agents.acme.example

defaults:
  model: anthropic:claude-sonnet-5
  policy: careful

roles:
  reader: {rules: [{verbs: [read, events], kinds: [agent]}]}
bindings:
  - {org: acme, role: operator, subjects: [user:acme/@ana, group:platform]}
  - {org: acme, role: reader, subjects: [agent:triage]}

mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    credential: github
    gated: [create_*]

oauth:
  providers:
    github:
      issuer: https://github.com/login/oauth
      client_id: ${GITHUB_CLIENT_ID}
      client_secret: ${GITHUB_CLIENT_SECRET}
      scopes: [repo]
      flow: device

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
    members: {U024BE7LH: user:acme/@ana}

notify:
  targets:
    ops: {channel: slack, room: "#ops"}
```

- The file is `config.yaml` in the [config directory](#directories). Without it, every key takes its default.
- Restart the daemon after a change. `wardrik doctor` checks the file without starting anything.
- An unknown key or a wrong value stops the daemon, naming the key's path.
- `${NAME}` reads the environment, then the [env file](#directories), then the deployment's vault
  secret `NAME` (`wardrik vault put NAME`). `vault`, `http` and `storage` read the environment only.

## Keys

| Key | Default | Description |
| --- | --- | --- |
| `org` | `default` | the deployment's own org |
| [`orgs`](#orgs) | `{}` | other orgs to run agents for |
| [`roles`, `bindings`](#roles-and-bindings) | `{}`, `[]` | who may do what |
| `base_url` | the HTTP API's URL | where people and services reach the daemon; webhooks and OAuth sign-ins come back under it |
| `deployment_keys` | `true` | let agents use API keys sealed as the deployment's when their owner holds none |
| `allow_private_urls` | `false` | let people add MCP servers, webhooks and OAuth apps at private addresses; local use only |
| [`defaults`](#defaults) | `{}` | what every agent gets where its definition says nothing |
| [`models`](#models) | `{}` | prices for models the catalog lacks |
| [`mcp`](#mcp) | `{}` | MCP servers agents may call |
| [`oauth`](#oauth) | none | services people sign in to |
| [`channels`](#channels) | `{}` | chat apps agents are reached through |
| [`notify`](#notify) | `{}` | where agents' notices go |
| [`workspace`](#workspace) | none | agents' workspaces other agents may mount |
| `brave.api_key` | none | the key `web_search` uses |
| `vault.keys` | `[]` | the vault's keys; `WARDRIK_VAULT_KEY` or a generated `vault_key` file unless set |
| [`http`](#http) | | where the HTTP API listens |
| [`storage`](#storage) | the node's disk | where everything is kept |
| `deployment` | `local` | the deployment's name in each event's `source` |
| `idle_timeout` | `900` | seconds an agent idles before it sleeps, or `infinity` |
| `retention` | `30` | days events are kept, or `infinity` |
| `triggers` | `{}` | options for triggers, like `req_options` for reading feeds |

`tools`, `tokens`, `cluster` and `ssh` are skipped with a warning.

## orgs

```yaml
orgs:
  "*":
    mcp: [search]
    policy: base
  payments:
    mcp: [stripe, github]
    channels: [payments-slack]
    notify: [audit]
    policy: payments-strict
```

| Key | Description |
| --- | --- |
| `mcp` | servers from [`mcp`](#mcp) its agents use |
| `channels` | channels from [`channels`](#channels) its agents use |
| `notify` | targets from [`notify`](#notify) its agents use |
| `policy` | a policy in `policies/` its agents are held to |

- `"*"` is every org. Every org uses what it lists, and is held to its policy.
- A server, channel or target no org lists is the deployment's org's.
- A channel serves one org, or every org if `"*"` lists it.

## roles and bindings

Who may do what, as in Kubernetes RBAC. A role is a list of rules; a binding gives a role to subjects in an org.

```yaml
roles:
  reader:
    rules:
      - {verbs: [read, events], kinds: [agent]}
  runbook-editor:
    rules:
      - {verbs: [define], kinds: [agent], names: [runbooks]}
bindings:
  - {org: payments, role: operator, subjects: [user:payments/@ana, group:payments-eng]}
  - {org: payments, role: reader, subjects: [agent:triage]}
  - {org: payments, role: runbook-editor, subjects: [group:sre]}
```

| Rule key | Description |
| --- | --- |
| `verbs` | the part of an action after the dot (`ask` for `agent.ask`), or `"*"` |
| `kinds` | `agent`, `ceiling`, `connection`, `deployment`, `mcp_server`, `notify_target`, `provider`, `secret`, `token`, or `"*"` |
| `names` | exact resources: agents by name, the rest by ID; every one unless set |

| Binding key | Description |
| --- | --- |
| `org` | the org it holds in, or `"*"` for every org and the deployment |
| `role` | a role from `roles`, or `operator` |
| `subjects` | `user:ORG/@NAME` for a person, `group:NAME`, or `agent:NAME` for that agent in the binding's org |

- `admin` is every verb on every kind. `user:admin` (the `wardrik` command) holds it in `"*"`. You can't declare it.
- `operator` is every verb on every kind, unless `roles` declares it.
- Everyone may do anything to what they own: their agents, secrets, servers, webhooks and OAuth apps.
- Everyone manages their own [connections](/reference/http-api/#daemon-connections).
- Making an agent is `create` on `agent`. A rule with `names` doesn't allow it.
- Removing a secret, server, webhook, OAuth app, connection or token is `delete`. Adding one doesn't allow it.
- An agent calling tools gets its own bindings (`agent:NAME`), never its owner's.
- A chat member acts as the user [`members`](#channels) maps them to. They may only `ask`, `read`,
  `events` and decide, on the agents of the workspace's owner.
- Tokens are in no org: only a binding in `"*"` reaches `token`. Only the admin makes a `user:admin` token.
- No binding reaches the org: `404`. A binding reaches it but no rule allows the verb: `403`.

Make tokens with [`wardrik token create`](/reference/cli/#tokens).

## defaults

What every agent gets where its definition says nothing. It takes any [agent file](/reference/agent-files/#keys)
key, like `model`, `tools`, `policy` or `retries`.

## models

Prices for models the catalog lacks, in dollars per million tokens.

```yaml
models:
  zai:glm-5.1: {input: 0.60, output: 2.20}
  zai_coding_plan:glm-5.1: {priced_as: zai:glm-5.1, markup: 0.1}
```

Keys: `input`, `output`, `cache_read`, `cache_write`, or `priced_as` another model; each with an optional `markup`.

## mcp

```yaml
mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    credential: github
    only: [list_commits, get_commit]
  notes:
    command: npx
    args: [-y, notes-mcp]
    timeout: 30
```

| Key | Description |
| --- | --- |
| `url`, `headers` | a Streamable HTTP endpoint, used as given |
| `command`, `args`, `env` | a program run over stdio; not with `url` |
| `only`, `except` | the server's tool names to take or leave |
| `prefix` | what its tool names start with; the server's name unless set |
| `credential` | the secret or connected account each owner reaches it with |
| `credential_header`, `credential_scheme` | `authorization` and `Bearer` unless set |
| `credential_env` | the variable a command gets the credential in |
| `timeout` | seconds a call may take; `60` |
| `max_result_bytes` | bytes of a result the model gets; `131072` |
| `cost` | each call's cost, as `{usd: 0.001}` |
| `gated` | tools that need a person's approval: `true`, `false`, or globs; tools not marked read-only unless set |
| `trusted` | `true` stops labelling its answers `outside` |

Agents name a server's tools as `github/*`. Orgs and people add their own with
[`wardrik server add`](/reference/cli/#mcp-servers-notify-targets-and-oauth-apps).

## oauth

```yaml
oauth:
  client_name: Acme agents
  providers:
    github:
      issuer: https://github.com/login/oauth
      client_id: ${GITHUB_CLIENT_ID}
      client_secret: ${GITHUB_CLIENT_SECRET}
      scopes: [repo]
      flow: device
```

- Each provider is named after the credential it grants.
- A provider takes `issuer`, `resource`, `authorization_endpoint`, `token_endpoint`, `client_id`,
  `client_secret`, `client_auth` (`post` or `basic`), `scopes`, `flow` (`browser` or `device`) and
  `authorization_params`.
- With `oauth` set, orgs and people can add their own OAuth apps, even with no `providers`.
- A browser sign-in comes back to `{base_url}/oauth/callback`.

## channels

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
    members: {U024BE7LH: user:acme/@ana, U0G9QF9C6: user:acme/@jon}
    unmapped_members: refuse
```

| Key | Description |
| --- | --- |
| `type` | required; `slack` |
| `token` | the bot token; without it, a token per workspace is kept in the vault |
| `signing_secret` | to take Slack's requests at `/v1/channels/NAME/` |
| `app_token` | to take them over Socket Mode instead |
| `client_id`, `client_secret`, `redirect_uri` | a Slack app added to many workspaces |
| `members` | the user each chat member acts as, by member ID |
| `unmapped_members` | `refuse` (default) tells unmapped members to ask an admin; `allow` lets them act as `user:slack:T0123/U024BE7LH` |
| `offering`, `deciding` | what a room with no agent, and a member who may not decide, is told |

- The name is lower-case letters, digits and `-`. `shell`, `ssh`, `terminal` and `oauth` are taken.
- An agent answers in a channel if its definition's [`channels`](/reference/agent-files/#keys) lists it.

See [Slack](/channels/slack/).

## notify

```yaml
notify:
  retries: {attempts: 5, max_wait: 30000}
  targets:
    ops: {channel: slack, room: "#ops"}
    audit: {webhook: {url: https://hooks.example.com/wardrik, secret: "${WEBHOOK_SECRET}"}}
```

- A target is a room (`channel`, `room`) or a `webhook` (`url`, `secret`).
- A target's name can't hold `:`.
- `retries` is how often a notice is sent again; `{attempts: 3, max_wait: 10000}` unless set.
- Orgs and people add their own webhooks over the [HTTP API](/reference/http-api/#add-a-notify-target).

## workspace

```yaml
workspace:
  shared:
    agent:runbooks:
      read: [agent:triage, agent:oncall]
      write: [agent:ops]
```

`shared` names the agents whose workspace others may mount, each with the agents that may `read` and
`write` it. Each is `agent:NAME`, an agent in the mounting agent's org.

## http

| Key | Default | Description |
| --- | --- | --- |
| `port` | `4747` | the port |
| `ip` | `127.0.0.1` | the address; `WARDRIK_HTTP_IP` unless set |
| `trusted_workers` | `false` | `true` treats tool workers' answers as the deployment's own |

## storage

```yaml
storage:
  postgres:
    url: postgres://wardrik:${PGPASSWORD}@db.internal:5432/wardrik
```

Without `storage`, everything is kept on disk in `WARDRIK_DATA_DIR`. See [Storage](/run/storage/).

## Directories

| Variable | Default | Holds |
| --- | --- | --- |
| `WARDRIK_CONFIG_DIR` | `~/.config/wardrik` | `config.yaml`, `agents/`, `policies/` |
| `WARDRIK_DATA_DIR` | `~/.local/share/wardrik/store` | the store |
| `WARDRIK_DATA_HOME` | `~/.local/share/wardrik` | `vault_key`, `cli_token` |
| `WARDRIK_STATE_DIR` | `~/.local/state/wardrik` | logs |
| `WARDRIK_ENV_FILE` | `env` in the config directory | extra environment variables |

The defaults follow `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME`.

```sh
# ~/.config/wardrik/env
ANTHROPIC_API_KEY=sk-ant-...
export SLACK_BOT_TOKEN="xoxb-..."
```
