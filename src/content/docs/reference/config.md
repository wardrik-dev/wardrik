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

- The file is `config.yaml` in the [config directory](#directories). If it's missing, every key uses its default.
- Restart the daemon after a change. `wardrik doctor` validates the file without starting the daemon.
- An unknown key or invalid value stops the daemon, with the key's path in the error.
- `${NAME}` resolves from the environment, then the [env file](#directories), then the deployment's vault
  secret `NAME` (`wardrik vault put NAME`). `vault`, `http` and `storage` resolve from the environment only.

## Keys

| Key | Default | Description |
| --- | --- | --- |
| `org` | `default` | the deployment's org |
| [`orgs`](#orgs) | `{}` | additional orgs |
| [`roles`, `bindings`](#roles-and-bindings) | `{}`, `[]` | access control |
| `base_url` | the HTTP API's URL | the daemon's public URL; webhook and OAuth callback URLs are under it |
| `deployment_keys` | `true` | agents fall back to deployment API keys when their owner has none |
| `allow_private_urls` | `false` | allow MCP servers, webhooks and OAuth apps at private addresses; local use only |
| [`defaults`](#defaults) | `{}` | default values for keys a definition omits |
| [`models`](#models) | `{}` | prices for models not in the catalog |
| [`mcp`](#mcp) | `{}` | MCP servers |
| [`oauth`](#oauth) | none | OAuth providers |
| [`channels`](#channels) | `{}` | chat apps |
| [`notify`](#notify) | `{}` | notice targets |
| [`workspace`](#workspace) | none | which agents can mount which workspaces |
| `brave.api_key` | none | the API key for `web_search` |
| `vault.keys` | `[]` | vault keys; default: `WARDRIK_VAULT_KEY` or a generated `vault_key` file |
| [`http`](#http) | | the HTTP API's listen address |
| [`storage`](#storage) | the node's disk | the store backend |
| `deployment` | `local` | the deployment name in each event's `source` |
| `idle_timeout` | `900` | idle seconds before an agent's process stops, or `infinity` |
| `retention` | `30` | days to keep events, or `infinity` |
| `triggers` | `{}` | trigger options, such as `req_options` for fetching feeds |

`tools`, `tokens`, `cluster` and `ssh` are ignored with a warning.

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
| `mcp` | servers from [`mcp`](#mcp) available to its agents |
| `channels` | channels from [`channels`](#channels) available to its agents |
| `notify` | targets from [`notify`](#notify) available to its agents |
| `policy` | a policy in `policies/` applied to all its agents |

- `"*"` matches every org. Its servers, channels, targets and policy apply to all orgs.
- A server, channel or target no org lists belongs to the deployment's org.
- A channel belongs to one org, or to every org if `"*"` lists it.

## roles and bindings

Access control, as in Kubernetes RBAC. A role is a list of rules. A binding grants a role to subjects in an org.

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
| `verbs` | the operation name after the dot (`ask` for `agent.ask`), or `"*"` |
| `kinds` | `agent`, `ceiling`, `connection`, `deployment`, `mcp_server`, `notify_target`, `provider`, `secret`, `token`, or `"*"` |
| `names` | exact resources: agents by name, others by ID; default: all |

| Binding key | Description |
| --- | --- |
| `org` | the org it applies in, or `"*"` for every org and the deployment |
| `role` | a role from `roles`, or `operator` |
| `subjects` | `user:ORG/@NAME`, `group:NAME`, or `agent:NAME` for that agent in the binding's org |

- `admin` is every verb on every kind. `user:admin` (the `wardrik` command) has it in `"*"`. It can't be declared.
- `operator` is every verb on every kind, unless `roles` declares it.
- Tokens aren't in an org, so only a binding in `"*"` applies to `token`.

Owners, agents, chat members and errors follow [built-in rules](/run/orgs/#built-in-rules).

## defaults

Default values for keys an agent definition omits. Takes any [agent file](/reference/agent-files/#keys)
key, such as `model`, `tools`, `policy` or `retries`.

## models

Prices for models not in the catalog, in dollars per million tokens.

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
| `only`, `except` | tool names to include or exclude |
| `prefix` | the tool name prefix; default: the server's name |
| `credential` | the secret or connected account name used for each owner |
| `credential_header`, `credential_scheme` | default `authorization` and `Bearer` |
| `credential_env` | the environment variable for a command server's credential |
| `timeout` | a call's limit in seconds; default `60` |
| `max_result_bytes` | maximum result size sent to the model; default `131072` |
| `cost` | each call's cost, as `{usd: 0.001}` |
| `gated` | tools that need approval: `true`, `false`, or globs; default: tools not marked read-only |
| `trusted` | `true` disables the `outside` label on its results |

Agents reference a server's tools as `github/*`. Orgs and users add their own with
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

- A provider's name is the credential name it supplies.
- Provider keys: `issuer`, `resource`, `authorization_endpoint`, `token_endpoint`, `client_id`,
  `client_secret`, `client_auth` (`post` or `basic`), `scopes`, `flow` (`browser` or `device`) and
  `authorization_params`.
- With `oauth` set, orgs and users can add their own OAuth apps, even without `providers`.
- Browser sign-ins redirect to `{base_url}/oauth/callback`.

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
| `token` | the bot token; without it, one token per workspace is stored in the vault |
| `signing_secret` | verifies Slack's requests at `/v1/channels/NAME/` |
| `app_token` | receives events over Socket Mode instead |
| `client_id`, `client_secret`, `redirect_uri` | for a Slack app installed in many workspaces |
| `members` | member ID to user |
| `unmapped_members` | `refuse` (default) replies with a message to ask an admin; `allow` maps them to `user:slack:T0123/U024BE7LH` |
| `offering`, `deciding` | messages for a room with no agent, and for a member who can't approve |

- The name is lower-case letters, digits and `-`. `shell`, `ssh`, `terminal` and `oauth` are reserved.
- An agent is available in a channel if its definition's [`channels`](/reference/agent-files/#keys) lists it.

See [Slack](/build/slack/).

## notify

```yaml
notify:
  retries: {attempts: 5, max_wait: 30000}
  targets:
    ops: {channel: slack, room: "#ops"}
    audit: {webhook: {url: https://hooks.example.com/wardrik, secret: "${WEBHOOK_SECRET}"}}
```

- A target is a room (`channel`, `room`) or a `webhook` (`url`, `secret`).
- A target name can't contain `:`.
- `retries` sets notice retries; default `{attempts: 3, max_wait: 10000}`.
- Orgs and users add their own webhooks over the [HTTP API](/reference/http-api/#add-a-notify-target).

## workspace

```yaml
workspace:
  shared:
    agent:runbooks:
      read: [agent:triage, agent:oncall]
      write: [agent:ops]
```

`shared` lists the agents whose workspaces can be mounted, each with the agents allowed to `read`
and `write` it. Each is `agent:NAME`, in the mounting agent's org.

## http

| Key | Default | Description |
| --- | --- | --- |
| `port` | `4747` | the port |
| `ip` | `127.0.0.1` | the listen address; default: `WARDRIK_HTTP_IP` |
| `trusted_workers` | `false` | `true` disables the `outside` label on tool worker results |

## storage

```yaml
storage:
  postgres:
    url: postgres://wardrik:${PGPASSWORD}@db.internal:5432/wardrik
```

Without `storage`, the store is on disk in `WARDRIK_DATA_DIR`. See [Storage](/run/storage/).

## Directories

| Variable | Default | Contents |
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
