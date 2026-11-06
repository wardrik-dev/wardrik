# WardrikDaemon

Wardrik as a daemon: agents from files, `config.yaml`, an HTTP API, and the `wardrik` command.

## Install

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik_daemon/releases/download/v0.1.0-rc.8/install.sh | WARDRIK_VERSION=0.1.0-rc.8 sh

wardrik init --org acme
```

`init` asks for a model provider, a model and its key. It then:

- writes `config.yaml`, `agents/assistant.md` (the assistant, the agent you ask for outcomes) and `env` to `~/.config/wardrik`.
  It never overwrites a file.
- starts the daemon, as a systemd user service where there's one.
- seals the key in the vault, unless the `env` file sets it.
- asks the assistant one short question.

Without a terminal, flags answer:

```sh
wardrik init --provider anthropic --model claude-sonnet-5 --key-from-env MY_KEY --no-service --no-ask
```

Tell the assistant what you want, as "tell me when https://github.blog/changelog/feed/ has a new
post". It proposes a worker and its triggers. Approve them with `wardrik approval approve`.

- The release runs on Linux (x86_64 or aarch64, glibc 2.35+). It installs to `~/.local/lib/wardrik`.
- `wardrik uninstall` stops the daemon and removes the release and its links. It keeps the config, keys
  and store; `--purge` deletes them too.
- Elsewhere, use the image:

  ```sh
  docker run -d --name wardrik -p 127.0.0.1:4747:4747 \
    -v wardrik-config:/config -v wardrik:/data ghcr.io/wardrik-dev/wardrik:0.1.0-rc.8
  docker exec -it wardrik wardrik init
  ```

- From a checkout: `mix release`, or `mix wardrik serve`, `mix wardrik ls` and so on.

## Agents

An agent is a Markdown file in `agents/`. The frontmatter is its definition; the body is its
instructions. This is `agents/triage.md`:

```markdown
---
description: Watches the incident queue and says what needs an engineer.
model: anthropic:claude-sonnet-5
tools: [linear/*, web_search]
policy: careful
triggers:
  - {name: daily, every: "0 9 * * *", timezone: America/Los_Angeles, prompt: What's new?}
org: payments    # the deployment's org unless set
owner: "@jon"    # its org unless set
---
You watch the incident queue. Summarise anything new, and say which issues need an engineer.
```

- The file name is the agent's name. A name is unique in its org.
- Missing keys come from `config.yaml`'s `defaults`.
- The daemon gives each agent an ID, as `agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN`. The API takes IDs;
  files, `config.yaml` and the `wardrik` command take names.
- Policies are YAML files: `policies/careful.yaml` is `policy: careful`.
- `wardrik reload` reads the files again. It restarts the daemon if `config.yaml` or `policies/`
  changed. A renamed file's agent gets a new ID.

Tools the daemon adds:

- `run_lua` - Lua in a sealed sandbox. See [WardrikLua](https://hexdocs.pm/wardrik_lua).
- `web_search` - Brave search. Needs `brave.api_key`. See [WardrikBrave](https://hexdocs.pm/wardrik_brave).
- `deep_research` - researches a topic with subagents. See [WardrikResearch](https://hexdocs.pm/wardrik_research).
- `agent_create` - makes a worker in the agent's org.
- `files` - the agent's own files. `context: [MEMORY.md]` reads one into every turn. See
  [WardrikWorkspace](https://hexdocs.pm/wardrik_workspace).

## config.yaml

```yaml
org: acme
base_url: https://agents.acme.example   # where people and services reach it

defaults:
  model: anthropic:claude-haiku-4-5

mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    credential: github
    only: [list_commits, get_commit]

oauth:
  providers:
    github:
      issuer: https://github.com/login/oauth
      resource: https://api.githubcopilot.com/mcp/
      client_id: ${GITHUB_CLIENT_ID}
      client_secret: ${GITHUB_CLIENT_SECRET}
      scopes: [repo]
      flow: device

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}        # Socket Mode; or signing_secret over HTTP
    domains: {acme.com: acme}            # ana@acme.com -> user:acme/@ana
    members: {U024BE7LH: user:acme/@jon} # one Slack member -> daemon user

notify:
  targets:
    ops: {channel: slack, room: "#ops"}
    audit: {webhook: {url: https://hooks.example.com/wardrik, secret: "${WEBHOOK_SECRET}"}}

orgs:
  payments:
    mcp: [github]
    policy: payments-strict

roles:
  reader: {rules: [{verbs: [read, events], kinds: [agent]}]}

bindings:
  - {org: acme, role: operator, subjects: [user:acme/@ana]}
  - {org: payments, role: reader, subjects: [group:payments-eng, agent:triage]}

brave:
  api_key: ${BRAVE_API_KEY}

http:
  port: 4747

storage:
  postgres:
    url: ${DATABASE_URL}
```

- `${NAME}` reads the environment, the `env` file, then the deployment's secret `NAME`.
  `vault`, `http`, `storage` and `cluster` read the environment only.
- An unknown key is an error that names its path:
  `config.yaml: oauth.providers.google: unknown options [:colour], valid options are: [...]`.
- Without `storage`, everything is kept on the node's disk. `storage` takes `postgres` or an S3
  bucket:

```yaml
storage:
  s3:
    bucket: wardrik
    endpoint: https://s3.us-east-1.amazonaws.com   # AWS, R2, Tigris or MinIO
    access_key_id: ${S3_ACCESS_KEY_ID}
    secret_access_key: ${S3_SECRET_ACCESS_KEY}
```

- `wardrik doctor` checks the file, running or not.

| Key | Reference |
| --- | --- |
| `org`, `base_url`, `defaults`, `models`, `workspace`, `vault`, `http`, `storage`, `brave` | `WardrikDaemon.Config` |
| `cluster` | `WardrikDaemon.Cluster` |
| `deployment_keys` | `WardrikDaemon.Keys` |
| `allow_private_urls` | `WardrikDaemon.Egress` |
| `deployment`, `idle_timeout`, `retention`, `triggers` | `Wardrik.start_link/1` |
| `mcp` | `WardrikDaemon.Config.MCP` |
| `oauth` | `WardrikDaemon.Config.OAuth` |
| `channels` | `WardrikDaemon.Config.Channels` |
| `notify` | `WardrikDaemon.Config.Notify` |
| `orgs` | `WardrikDaemon.Config.Orgs` |
| `roles`, `bindings` | `WardrikDaemon.Config.Access` |

### Orgs

- The orgs are `org` and each key of `orgs`. Any other org is refused.
- `orgs.<org>` lists the servers, channels and notify targets its agents use, and its policy.
  `"*"` applies to every org.
- Anything no org lists belongs to the deployment's `org`.
- A policy's budget is shared by all of the org's agents.

### Roles and bindings

- A rule allows `verbs` (`ask` for `agent.ask`) on `kinds`: `agent`, `secret`, `ceiling`,
  `mcp_server`, `notify_target`, `provider`, `connection`, `deployment`, `token`.
- A binding gives a role to a person (`user:acme/@ana`), `group:NAME` or `agent:NAME` in one
  org, or in `"*"`.
- Removing a secret, server, webhook, OAuth app, connection or token is `delete`, not the verb
  that adds it.
- `operator` (every verb, every kind) exists unless you declare it. `user:admin`, the `wardrik`
  command, can do everything.
- Everyone may do anything to what they own, and manage their own connections.
- An agent calling tools gets its own bindings, never its owner's.
- A chat member acts as the user `members` maps them to, or as the user their email address
  names in an org `domains` maps its domain to. Others are refused.
- Outside their orgs, people find nothing.

### API keys

Agents use keys sealed for `api_key`: their owner's, then the owner's org's, then the
deployment's. Set `deployment_keys: false` to make every org bring its own.

```sh
echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY --for api_key
echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY --org payments --for api_key
```

## Signing in to accounts

```sh
wardrik connection connect github
```

- A device sign-in shows a code to enter at the provider. The command waits until the sign-in is
  granted, declined or expired.
- A browser sign-in shows a URL. After you sign in, the page shows a code, as `BCDF-GHJK`. Type it
  where the command asks, or run `wardrik connection pair github BCDF-GHJK`.
- A code works once, for 10 minutes, for the person who started the sign-in. 5 wrong codes end it.
- `wardrik connection ls` shows each account, whether it's connected, and whether a sign-in is
  under way.

Orgs and people can add their own MCP servers, webhooks and OAuth apps while the daemon runs:

```sh
wardrik server add crm --url https://crm.example.com/mcp --secret CRM_KEY --org payments
wardrik notify add hooks --url https://hooks.example.com/in --secret HOOK_SECRET --org payments
wardrik provider add linear --issuer https://linear.app --client-id ID --secret LINEAR_SECRET --org payments
```

- The nearest of a name wins: a person's own, their org's, then the deployment's.
- Their URLs must be `https` at a public address. Set `allow_private_urls: true` for local use only.

## Clusters

Several daemons run as one cluster. Any node answers for all of them. When a node is lost, its
agents carry on on another, still waiting on the calls they waited on.

```yaml
cluster:
  nodes: [a, b, c]
```

Short names are nodes on one machine. They share the config, the cookie, the vault's key and the
HTTP API's port. Each keeps its own store and logs under `nodes/<name>/`.

```sh
wardrik start --node a
wardrik start --node b
wardrik start --node c
wardrik status            # the nodes, and how many agents run on each
wardrik logs --node b
wardrik service install --node a   # each node is an instance of wardrik@.service
```

### Spread agents

```yaml
agents:
  max_per_node: 5000   # agents and conversations a node runs
  max_memory: 80       # percent of the machine's memory
  max_cpu: 90          # percent of its CPU
  hibernate_after: 60  # seconds idle before an agent compacts its memory
```

- Each new agent, and each agent a lost node ran, starts on the node with the most room. With
  none of these set, it starts on the node that defined it.
- A node at `max_per_node` takes no more. Leave room on the rest for a lost node's agents.
- Nodes on one machine share its memory and CPU, so there only `max_per_node` spreads agents.
- Running agents stay where they are. `wardrik agent move AGENT NODE` moves one.
- Measured on one machine, three nodes, `max_per_node: 15`: 30 agent files started as 1, 14 and
  15 per node. Placement reads each node's load from heartbeats every 10s, so a burst fills a node
  to its limit before the next. After `kill -9` of the node with 15, all 30 ran on the other two
  within 47s.

With the store on the nodes' disks, a write needs more than half the nodes. Three nodes carry on
with one lost; two stop when either is. A node starting waits for enough others, up to an hour.
With `storage` in Postgres or S3, nodes don't wait for each other.

On several machines, name one node per machine in full, or find them by DNS:

```yaml
cluster:
  nodes: [wardrik@box1, wardrik@box2, wardrik@box3]
# or
cluster:
  dns: wardrik.internal   # a node named wardrik@ADDRESS at each A and AAAA record
  size: 3
```

Each machine's `env` file names its node and where distribution listens:

```sh
WARDRIK_NODE=wardrik@box1
WARDRIK_DIST_INTERFACE={100,64,0,1}   # this machine's address on the private network
WARDRIK_DIST_EXPOSED=1
RELEASE_COOKIE=...                    # the same on every node
```

- Erlang distribution isn't encrypted, and anyone who reaches a node with its cookie can run code
  on it. Run nodes on a private network that encrypts, such as Tailscale or WireGuard.
- Give every node the same vault key, and the same agent and policy files.
- Open epmd's port, 4369, and each node's distribution port between the machines.
- A node `cluster.nodes` doesn't name refuses to start.

See `WardrikDaemon.Cluster`.

## The wardrik command

`wardrik help` lists every command. `wardrik help COMMAND` explains one. Every command takes
`--json`.

```sh
wardrik ls
wardrik ask triage "What's new?"
wardrik approval ls
wardrik approval approve triage CALL
wardrik token create ana-laptop --subject user:acme/@ana --groups payments-eng --expires 30d
```

- An agent is `triage` in the deployment's org, or `payments/triage` in another.
- `--conversation ID` acts on one conversation, as a Slack thread's.
- The command acts as `user:admin` with the token in `cli_token`. `WARDRIK_URL` and
  `WARDRIK_TOKEN` point it at another daemon.

## The HTTP API

The daemon serves Wardrik's operations (`Wardrik.HTTP`) and its own routes, described in
`priv/openapi.json`. See `WardrikDaemon.HTTP`.

```sh
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/connections
```

## Directories

| Variable | Default | Holds |
| --- | --- | --- |
| `WARDRIK_CONFIG_DIR` | `~/.config/wardrik` | `config.yaml`, `agents/`, `policies/`, `env` |
| `WARDRIK_DATA_DIR` | `~/.local/share/wardrik/store` | the store |
| `WARDRIK_DATA_HOME` | `~/.local/share/wardrik` | `vault_key`, `cli_token`, `cookie` |
| `WARDRIK_STATE_DIR` | `~/.local/state/wardrik` | logs |
| `WARDRIK_ENV_FILE` | `env` in the config directory | extra environment variables |
| `WARDRIK_NODE` | none | which node of a cluster this is |
