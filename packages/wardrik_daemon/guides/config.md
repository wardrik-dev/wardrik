# config.yaml

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
    admins: ["@jon"]

notify:
  ops:
    channel: slack
    room: "#ops"
    approvers: ["@maria"]
```

The file is `config.yaml` or `config.yml`, in YAML 1.2; a directory holding both is refused. The
daemon reads it as it starts, so restart it after a change. It refuses a file with a variable that
isn't set, a key nothing takes, or a name it doesn't define, and says where.

## Secrets

`${NAME}` in any string is replaced with that environment variable or, where the environment doesn't
set it, the deployment's secret of that name in the vault, which `wardrik vault put NAME` seals.
Either way the file holds no secret.

`storage`, `cluster`, `http` and `vault` read the environment alone, since they are read before the
vault can be opened. The environment is the daemon's, with the env file's variables where it doesn't
set them.

## Keys

| Key | What it configures |
| --- | --- |
| [`org`](#org) | the deployment's org |
| [`orgs`](#orgs) | the other orgs, what each uses, and the ceiling each is held to |
| [`base_url`](#base_url) | the address people and services reach the daemon at |
| [`defaults`](#defaults) | what an agent is given where nothing else says |
| [`tools`](#tools) | what calls to a tool cost |
| [`mcp`](#mcp) | MCP servers whose tools agents may call |
| [`oauth`](#oauth) | providers people connect accounts with |
| [`channels`](#channels) | chat media agents are reached through, such as Slack |
| [`notify`](#notify) | where agents' notices go |
| [`workspace`](#workspace) | the trees of files agents beyond their owners may share |
| [`vault`](#vault) | the vault's keys, and the secrets every agent may read |
| [`storage`](#storage) | the store everything is kept in |
| [`cluster`](#cluster) | the other daemons this one runs with |
| [`http`](#http) | where the HTTP API listens |
| [`ssh`](#ssh) | where the terminal client listens |

## org

The org an agent belongs to where its file names none, and the one the CLI finds an agent in when
it is named without an org. `default` unless set.

## orgs

The orgs beside the deployment's own, each with the servers, channels and notify targets its agents
use, and the ceiling they are held to. Each server, channel and target is defined once, under `mcp`,
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
    ceiling: base
  payments:
    mcp: [stripe, github]
    channels: [payments-slack]
    ceiling: payments-ceiling
  growth:
    mcp: [github]
    channels: [growth-slack]

vault:
  shared: [SEARCH_API_KEY]
```

- An org's entry takes `mcp`, `channels` and `notify`, each a list of names, and `ceiling`. An
  entry may be empty, `growth: {}`.
- `ceiling` names a policy in `policies/` that every agent of the org is held to, ahead of its own,
  whether a file, the HTTP API or a channel defined it. A definition can narrow it, never widen it.
  Its budget is the org's: all of the org's agents spend from it together.
  An org whose ceiling `policies/` doesn't hold runs none of its agents.
- `"*"` lists what every org uses, and its `ceiling` holds every org, beside the org's own; each
  org spends its budget apart.
- A server, channel or target no entry lists is the deployment's own org's.
- An agent, a secret, a token's scope or a shared tree in an org that is neither `org` nor in
  `orgs` is refused, as is a name its section doesn't define.

Each org's agents reach a server with their org's own credential, so payments and growth each seal a
`GITHUB_TOKEN` of their own. `vault.shared` lets every org use the deployment's `SEARCH_API_KEY`. See
[Credentials](#credentials).

## base_url

The deployment's address as people and services reach it through whatever is in front of the
daemon: an `https://` URL, or `http://` on loopback. Webhook triggers are sent requests under it, at
`/v1/hooks/`, and a provider sends a browser back to `{base_url}/oauth` unless `oauth.redirect.url`
says otherwise. Without it the deployment is this machine's loopback.

## defaults

What an agent is given where its file says nothing, and what `wardrik agent spawn` writes into a new
one. It takes `model`, `tools`, `policy`, `timeout`, `idle_timeout`, `max_iterations`, `retries` and
`compaction`, as an [agent file](agent-files.md) does. Where neither sets them, `idle_timeout` is
900 seconds, and [`retries`](agent-files.md#retries) tries a failed model call six more times,
waiting at most a minute between tries, then asks a person. `wardrik init` writes `model`.

## tools

What one call to a tool costs, in US dollars, for a tool that doesn't report its own cost, such as
an MCP server's. A budget counts it.

```yaml
tools:
  web_search:
    price: 0.005
  github/*:
    price: 0.001
```

A tool is named as a [policy](`e:wardrik:policies.html`) names one. A name given whole wins
over a pattern, and a longer pattern over a shorter.

## mcp

MCP servers, each by a name of the deployment's own, which is how agents and policies name its
tools: `linear/*`. A server is run as a command, with `command`, or reached over HTTP, with `url`.

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
| `command`, `args`, `env`, `cwd` | the command that runs the server |
| `url`, `headers` | where the server is reached over HTTP |
| `only`, `except` | the tools it offers, by the names the server gives them |
| `prefix` | what its tool names start with; the server's name unless set |
| `timeout` | seconds a call may take; 60 unless set |
| `max_result_bytes` | how much of a call's answer reaches the model; 128 KB unless set |
| `gated` | the tools whose calls wait on a person unless a rule allows them by name; `true` or `false` for all or none; every tool the server doesn't mark read-only unless set |
| `trusted` | `true` where the server's answers are the deployment's own, so they aren't labelled `outside` |
| `credential` | the name of the credential the server is reached with |
| `credential_header`, `credential_scheme` | the header a credential is sent in and its scheme; `authorization` and `Bearer` unless set |
| `credential_env` | the variable a credential is given to a command in |

A server's name and `prefix` may not hold `__`. It serves the orgs that [`orgs`](#orgs) lists it
for. See
[Connect MCP servers](https://docs.wardrik.dev/build/mcp/).

### Credentials

A credential is sealed in the vault and found for each call as the agent's owner holds it: the user
it works for (`wardrik vault put NAME --user USER`), or its org (`--org ORG`) for an agent that
works for nobody. One owner never reads another's. The deployment's own (`wardrik vault put NAME`),
and the daemon's environment variable of that name, reach an agent only where
[`vault.shared`](#vault) names them. Where the owner holds none and `oauth` has a provider of the
same name, the owner is asked to connect an account. See [Connect
accounts](https://docs.wardrik.dev/build/accounts/).

## oauth

```yaml
oauth:
  providers:
    github:
      resource: https://api.githubcopilot.com/mcp/
      issuer: https://github.com/login/oauth
      client_id: ${GITHUB_CLIENT_ID}
      client_secret: ${GITHUB_CLIENT_SECRET}
      scopes: [repo]
```

`providers` names a provider for each credential people connect, `client` what a provider's consent
screen shows (`name`, `client_uri`, `logo_uri` and the like), and `redirect` where a provider sends
the browser back. `redirect.url` is an `https://` URL served by something in front of the daemon,
which passes requests to where `redirect.ip` and `redirect.port` say; each provider is under
`callback/NAME`. Without it, the callback is this machine's loopback. See [A public
address](https://docs.wardrik.dev/run/public-address/).

## channels

Chat media agents are reached through, each by a name of the deployment's own.

| Key | Means |
| --- | --- |
| `type` | the kind of channel, such as `slack` |
| `token` | the token it acts with in the one workspace it reaches, such as a Slack bot token; without one, nothing is posted |
| `approvers` | who decides what an agent waits on in its rooms: the people named, or `anyone` in the channel; where none are named, whoever asked for the turn decides, and a shell decides the rest |
| `admins` | who may change its orgs' agents |
| `create` | `false` stops people creating an agent in a room that has none; where `defaults` name a policy, one is made from them unless set |

The rest of a channel's keys are its kind's, such as Slack's `signing_secret` and `app_token`. What
its medium sends it over HTTP reaches the daemon at `/v1/channels/NAME/`; see [`http`](#http). A
channel
offers the agents of the orgs that [`orgs`](#orgs) lists it for. An agent is offered in a channel's
rooms where its file lists the channel. See
[Channels](https://docs.wardrik.dev/channels/) and
[Slack](https://docs.wardrik.dev/channels/slack/).

## notify

Targets an agent's `notify` sends notices to, each a room of a channel or a webhook.

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

A room target takes `channel`, which names a `token` to post with, `room`, and `approvers`, who may
answer it. A webhook takes `url` and
optionally `secret`. A target tells the agents of the orgs that [`orgs`](#orgs) lists it for. See
[Send notices](https://docs.wardrik.dev/build/notices/).

## workspace

`shared` names the trees agents beyond their owners may mount, each with the agents, by key prefix,
that may `read` it and those that may `write` it. An agent still names each tree it mounts in its
own [`workspace`](agent-files.md#workspace).

```yaml
org: acme

workspace:
  shared:
    acme/runbooks:
      read: ["acme/*"]
      write: [acme/ops]
```

## vault

`keys` lists the vault's keys. Without them, or `WARDRIK_VAULT_KEY`, the key is `vault_key` in the
data home, which the first `wardrik vault put` offers to make.

`shared` names the deployment's secrets every agent may read, such as a search tool's key:

```yaml
vault:
  shared: [SEARCH_API_KEY]
```

## storage

The store everything is kept in, one of:

- `postgres`, with `url`, a `postgres://` URL. The daemon creates its table as it starts.
- `s3`, with `bucket`, `endpoint`, `access_key_id` and `secret_access_key`, and optionally `region`
  and `prefix`.

```yaml
storage:
  s3:
    bucket: wardrik
    endpoint: https://<account>.r2.cloudflarestorage.com
    region: auto
    access_key_id: ${R2_ACCESS_KEY_ID}
    secret_access_key: ${R2_SECRET_ACCESS_KEY}
```

Without `storage`, the store is on the node's disk under `WARDRIK_DATA_DIR`. See
[Storage](https://docs.wardrik.dev/run/storage/).

## cluster

`nodes` lists the cluster's nodes, or `dns` names a DNS name each node's address is found at, with
`size` the number of nodes there should be. A store kept on the nodes counts a quorum over them. See
[Run a cluster](https://docs.wardrik.dev/run/cluster/).

## http

`port` and `ip` for the HTTP API, `127.0.0.1:4747` unless set, and `trusted_workers: true` where
tool workers' answers are the deployment's own. See [HTTP API](`e:wardrik_http:http-api.html`).
Beside the API, it serves what each channel's medium sends under `/v1/channels/`, and what services
send webhook triggers under `/v1/hooks/`; see
[A public address](https://docs.wardrik.dev/run/public-address/).

## ssh

`port` and `ip` for the terminal client. See
[The terminal client](https://docs.wardrik.dev/build/tui/).

## Directories

The daemon follows the XDG base directories, so what a person writes stays apart from what the
daemon writes. Each is moved by its environment variable.

| Variable | Default | Holds |
| --- | --- | --- |
| `WARDRIK_CONFIG_DIR` | `~/.config/wardrik` | `config.yaml`, `agents/` and `policies/` |
| `WARDRIK_DATA_DIR` | `~/.local/share/wardrik/store` | the store |
| `WARDRIK_DATA_HOME` | `~/.local/share/wardrik` | `vault_key`, where no vault key is configured |
| `WARDRIK_COOKIE_FILE` | `~/.local/share/wardrik/cookie` | the node's cluster cookie |
| `WARDRIK_STATE_DIR` | `~/.local/state/wardrik` | `log/wardrik.log`, and `log/mcp.log` for what MCP commands write to stderr |
| `WARDRIK_ENV_FILE` | `env` in `WARDRIK_CONFIG_DIR` | variables the daemon sets where its environment doesn't, one `NAME=value` a line |

Each default follows `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME` and `$XDG_STATE_HOME` where they are set.
