---
title: "config.yaml"
description: "Daemon settings for models, integrations, access control, networking, and storage."
sidebar:
  order: 2
---

Configure the daemon in `config.yaml`. Agent-specific settings belong in [agent files](/reference/agent-files/).

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
    domains: {acme.com: acme}

notify:
  targets:
    ops: {channel: slack, room: "#ops"}
```

- The file is `config.yaml` in the [config directory](#directories). If it's missing, every key uses its default.
- Restart the daemon after a change. `wardrik doctor` validates the file without starting the daemon.
- An unknown key or invalid value prevents startup. The error identifies the setting.
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
| [`models`](#models) | `{}` | prices, call options and the gateway for models |
| [`mcp`](#mcp) | `{}` | MCP servers |
| [`oauth`](#oauth) | none | OAuth providers |
| [`channels`](#channels) | `{}` | chat apps |
| [`notify`](#notify) | `{}` | notice targets |
| [`workspace`](#workspace) | none | which agents can mount which workspaces |
| `brave.api_key` | none | the API key for `web_search` |
| `vault.keys` | `[]` | vault keys; default: `WARDRIK_VAULT_KEY` or a generated `vault_key` file |
| [`http`](#http) | | the HTTP API's listen address |
| [`storage`](#storage) | the node's disk | the store: Postgres or S3 |
| `deployment` | `local` | the deployment name in each event's `source` |
| `idle_timeout` | `900` | idle seconds before an agent's process stops, or `infinity` |
| `retention` | `30` | days to keep events, or `infinity` |
| `triggers` | `{}` | trigger options, such as `req_options` for fetching feeds |
| [`cluster`](#cluster) | one node | the nodes that run as one |
| [`agents`](#agents) | `{}` | agent placement and idle memory settings |

`tools`, `tokens` and `ssh` are ignored with a warning.

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

Access control follows the Kubernetes RBAC model. Roles define permitted operations; bindings
grant roles to users, groups, or agents in an organization.

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

- The built-in `admin` role permits all operations on all resources. The CLI’s `user:admin` has
  this role across all organizations. It cannot be redefined.
- The built-in `operator` role permits all operations on all resource types within its binding’s
  scope, unless overridden in `roles`.
- Tokens aren't in an org, so only a binding in `"*"` applies to `token`.

Owners, agents, chat members and errors follow [built-in rules](/run/orgs/#built-in-rules).

## defaults

Set defaults for omitted agent settings. Accepts any [agent configuration field](/reference/agent-files/#keys),
such as `model`, `tools`, `policy`, or `retries`.

## models

```yaml
models:
  prices:
    zai:glm-5.1: {input: 0.60, output: 2.20}
    zai_coding_plan:glm-5.1: {priced_as: zai:glm-5.1, markup: 0.1}
  options: {temperature: 0.2, receive_timeout: 600000}
  gateway:
    fallbacks: {anthropic:claude-sonnet-4-5: [openai:gpt-5]}
    limits: {anthropic: {requests_per_minute: 4000, tokens_per_minute: 400000}}
```

| Key | Default | Description |
| --- | --- | --- |
| `prices` | `{}` | prices for models not in the catalog, in dollars per million tokens |
| `options` | `{}` | options passed to [ReqLLM](https://hexdocs.pm/req_llm) for every model call |
| `gateway` | breakers only | fallbacks, limits and breakers every model call goes through; see [Model gateway](/run/model-gateway/) |

- A price takes `input`, `output`, `cache_read`, `cache_write`, or `priced_as` another model; each
  with an optional `markup`.
- `options` accepts settings supported by ReqLLM, such as `base_url`. Timeouts are in
  milliseconds. Agent-level [`model_options`](/reference/agent-files/#model_options) override these defaults.
- `wardrik reload` applies changes to all of them.

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
    domains: {acme.com: acme}
    members: {U0G9QF9C6: user:acme/@jon}
```

| Key | Description |
| --- | --- |
| `type` | required; `slack` |
| `token` | the bot token; without it, one token per workspace is stored in the vault |
| `signing_secret` | verifies Slack's requests at `/v1/channels/NAME/` |
| `app_token` | receives events over Socket Mode instead |
| `client_id`, `client_secret`, `redirect_uri` | for a Slack app installed in many workspaces |
| `domains` | email domain to org; `ana@acme.com` acts as `user:acme/@ana` |
| `members` | member ID to user; wins over `domains` |
| `offering`, `deciding` | messages for a room with no agent, and for a member who can't approve |

- The name is lower-case letters, digits and `-`. `shell`, `ssh`, `terminal` and `oauth` are reserved.
- Members without a `domains` or `members` mapping receive an access-denied message.
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
# or
storage:
  s3:
    bucket: wardrik
    endpoint: https://<account>.r2.cloudflarestorage.com
    region: auto
    access_key_id: ${S3_ACCESS_KEY_ID}
    secret_access_key: ${S3_SECRET_ACCESS_KEY}
```

| `s3` key | Default | Meaning |
| --- | --- | --- |
| `bucket` | required | the bucket, which must exist |
| `endpoint` | required | the service's URL; requests are path-style |
| `access_key_id`, `secret_access_key` | required | the key |
| `region` | `us-east-1` | as the service names it |
| `session_token` | none | for temporary credentials |
| `prefix` | `wardrik` | object key prefix within the bucket |
| `headers` | `{}` | sent with every request |

Configure either `postgres` or `s3`. Without `storage`, the store is on disk in `WARDRIK_DATA_DIR`.
See [Storage](/run/storage/).

## cluster

```yaml
cluster:
  nodes: [a, b, c]
```

| Key | Description |
| --- | --- |
| `nodes` | short names for nodes on one machine, or full names, one per machine |
| `dns` | a name whose A and AAAA records are the nodes, as `wardrik@ADDRESS` |
| `size` | the number of nodes, with `dns` |

`cluster` is read as the daemon starts. See [Run a cluster](/run/cluster/).

## agents

```yaml
agents:
  max_per_node: 5000
  max_memory: 80
  max_cpu: 90
  hibernate_after: 60
```

| Key | Default | Description |
| --- | --- | --- |
| `max_per_node` | none | agents and conversations a node runs |
| `max_memory` | none | percent of the machine's memory above which a node takes no new agents |
| `max_cpu` | none | percent of its CPU above which a node takes no new agents |
| `hibernate_after` | none | seconds idle before an agent compacts its memory |

New agents start on the node with the most available capacity. See
[Spread agents](/run/cluster/#spread-agents).

## Directories

| Variable | Default | Contents |
| --- | --- | --- |
| `WARDRIK_CONFIG_DIR` | `~/.config/wardrik` | `config.yaml`, `agents/`, `policies/` |
| `WARDRIK_DATA_DIR` | `~/.local/share/wardrik/store` | the store |
| `WARDRIK_DATA_HOME` | `~/.local/share/wardrik` | `vault_key`, `cli_token` |
| `WARDRIK_STATE_DIR` | `~/.local/state/wardrik` | logs |
| `WARDRIK_ENV_FILE` | `env` in the config directory | extra environment variables |
| `WARDRIK_NODE` | none | which node of a [cluster](/run/cluster/) this is |

The defaults follow `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME`.

```sh
# ~/.config/wardrik/env
ANTHROPIC_API_KEY=sk-ant-...
export SLACK_BOT_TOKEN="xoxb-..."
```
