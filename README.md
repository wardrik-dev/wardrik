# WardrikDaemon

Wardrik as a daemon: agents from files, `config.yaml`, an HTTP API, and the `wardrik` command.

## Try it

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik_daemon/releases/download/v0.1.0-rc.2/install.sh | WARDRIK_VERSION=0.1.0-rc.2 sh

wardrik init --org acme
```

`init` asks what it needs and says what it does:

1. the model provider, those whose key is set here first, and the model: `claude-haiku-4-5` for
   Anthropic.
2. the provider's key, not shown as you type, unless the environment or the env file sets it.
3. three files, keeping any already there:
   * `~/.config/wardrik/config.yaml` - the deployment's settings, with the default model.
   * `~/.config/wardrik/agents/assistant.md` - the front door.
   * `~/.config/wardrik/env` - keys the daemon reads. Only you can read it.
4. the daemon, as a systemd user service where there's one, or else with `wardrik start`.
5. the key, sealed in the vault, unless the env file sets it.
6. the front door, asked one short question.

Without a terminal, flags answer:

```sh
wardrik init --provider anthropic --model claude-sonnet-5 --key-from-env MY_KEY --no-service --no-ask
```

`--yes` runs the daemon as a systemd service. To keep the key yourself, put it in the env file
before `init`, and it's read from there:

```sh
echo 'ANTHROPIC_API_KEY=sk-ant-...' >> ~/.config/wardrik/env
```

The front door gets `web_search` where `BRAVE_API_KEY` is set as you run `init`. Elsewhere
`config.yaml` says how to turn it on.

The daemon runs in the background. Every other command reaches it over its HTTP API, at
`127.0.0.1:4747` unless `config.yaml` says otherwise.

A key sealed in the vault is read as each call is made, so a new key needs no restart. Add `--org`
to seal an org's own key.

```sh
echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY --for api_key
```

Tell the front door an outcome, as "tell me when https://elixir-lang.org/atom.xml has a new post".
It proposes the work as the calls that do it: a worker it defines, and the triggers that start it.
Approve them with `wardrik approval approve`, and the work runs on its own. The front door's body
is its instructions, then a playbook to edit as you like.

The installer checks the release against its `SHA256SUMS`, puts it in `~/.local/lib/wardrik`
beside the one before it, and `wardrik` in `~/.local/bin`. Without `WARDRIK_VERSION` it installs
the newest release, pre-releases included. The release runs on Linux, x86_64 or aarch64, with
glibc 2.35 or later. Elsewhere, run the image:

```sh
docker run -d --name wardrik -p 127.0.0.1:4747:4747 \
  -v wardrik-config:/config -v wardrik:/data ghcr.io/wardrik-dev/wardrik:0.1.0-rc.2
docker exec -it wardrik wardrik init
```

`docker build .` builds the image, and `docker build --target tarball --output dist .` the
tarball.

In a checkout of this repository, `mix release` builds the same release. Without one,
`mix wardrik serve`, `mix wardrik ls` and the rest run the same commands.

## Agents

An agent is a Markdown file in `agents/`. The frontmatter is its definition, and the body is its
instructions:

```markdown
---
description: Watches the incident queue and says what needs an engineer.
model: anthropic:claude-sonnet-5
tools: [linear/*]
policy: careful
triggers:
  - {name: daily, every: "0 9 * * *", timezone: America/Los_Angeles, prompt: What's new?}
channels: [slack]
---
You watch the incident queue. Summarise anything new, and say which issues need an engineer.
```

The file's name is the agent's name, `triage` here. A name is unique in its org. Keys the file
leaves out come from `config.yaml`'s `defaults`. Two keys say whose agent it is:

```yaml
org: growth        # the deployment's org unless set
owner: "@jon"      # its org unless set; a person in it, as growth/@jon
```

The daemon gives each agent an ID, as `agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN`. The API and SDKs take
IDs; `config.yaml`, agent files and the `wardrik` command take names.

`wardrik reload` reads the files again. If `config.yaml` or `policies/` changed, the daemon restarts
to read them, and defines the agents as it starts. Otherwise:

* a changed file's agent uses its new definition from its next turn, and keeps its ID.
* a removed or renamed file's agent is forgotten. A renamed file's agent gets a new ID.
* a file that doesn't read is logged, and `wardrik doctor` says why.
* a file can't take a name another agent of its org has, nor hand its agent to another owner.

The API can't forget an agent a file declares.

The daemon offers three tools of its own:

* `run_lua` - Lua in a sealed sandbox, for arithmetic, reshaping data and the current time. See
  [WardrikLua](https://hexdocs.pm/wardrik_lua).
* `web_search` - searches through Brave. Needs `brave.api_key`. See
  [WardrikBrave](https://hexdocs.pm/wardrik_brave).
* `deep_research` - splits a topic into angles, and has a subagent with the agent's own tools
  research each at once. See [WardrikResearch](https://hexdocs.pm/wardrik_research).

With `files` in its `tools`, an agent keeps its own tree of files in the store. `context:
[MEMORY.md]` reads files into every turn: that's its memory. See
[WardrikWorkspace](https://hexdocs.pm/wardrik_workspace).

Policies are YAML files in `policies/`, by name: `policies/careful.yaml` is `policy: careful`.

## config.yaml

```yaml
org: acme
base_url: https://agents.acme.example   # where people and services reach it

defaults:
  model: anthropic:claude-haiku-4-5

mcp:
  github:
    url: https://api.githubcopilot.com/mcp/   # its full endpoint, used as given
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
    app_token: ${SLACK_APP_TOKEN}       # Socket Mode; or signing_secret, over HTTP
    members: {U024BE7LH: user:ana}      # the user each chat member acts as

brave:
  api_key: ${BRAVE_API_KEY}             # web_search; or seal it: wardrik vault put BRAVE_API_KEY --for api_key

notify:
  targets:
    ops: {channel: slack, room: "#ops"}
    audit: {webhook: {url: https://hooks.example.com/wardrik, secret: "${WEBHOOK_SECRET}"}}

http:
  port: 4747
  ip: 127.0.0.1

storage:
  postgres:
    url: ${DATABASE_URL}                # postgres://user:pass@host/db; ?ssl=true for TLS
```

`defaults` is what every agent gets where its definition says nothing. That holds however it was
defined: from a file, over the HTTP API, or by the front door.

`${NAME}` is replaced with the environment variable `NAME`, one the `env` file sets, or the
deployment's secret `NAME`, which `wardrik vault put NAME --for PURPOSE` seals. `vault`, `http`
and `storage` are read before the vault opens, so they take the environment alone.

An unknown key, or a value its option doesn't take, is an error, and the daemon says where:

```
config.yaml: oauth.providers.google: unknown options [:colour], valid options are: [:issuer, ...]
```

`tools`, `tokens`, `cluster` and `ssh` aren't supported yet, and are skipped with a warning.

The vault's key is `vault.keys`, or `WARDRIK_VAULT_KEY`, or `vault_key` in the data home, made the
first time the daemon starts.

### Sections

Where a section holds a library's options, it takes them by name, as that library documents them.
YAML writes an atom as a string, `flow: device`, and a keyword list as a map,
`req_options: {receive_timeout: 5000}`.

| Key | What it is | Its options |
| --- | --- | --- |
| `org`, `base_url`, `defaults`, `vault`, `http`, `brave` | The deployment, its HTTP API and `web_search` | `WardrikDaemon.Config` |
| `deployment_keys` | Whether agents fall back to the deployment's API keys | `WardrikDaemon.Keys` |
| `deployment`, `idle_timeout`, `retention`, `triggers` | Wardrik itself | `Wardrik.start_link/1` |
| `mcp` | MCP servers agents may call | `WardrikMCP.Server`, see `WardrikDaemon.Config.MCP` |
| `oauth` | Services people sign in to, and the deployment's `providers` | `Wardrik.start_link/1`'s `:oauth`, `WardrikOAuth.Provider`, `WardrikDaemon.OAuthApps` |
| `channels` | Chat apps agents are reached through | `WardrikChannel`, `WardrikSlack` |
| `notify` | Where agents' notices go | `Wardrik.Notify`, `Wardrik.Notify.Room`, `Wardrik.Notify.Webhook` |
| `orgs` | The orgs beside the deployment's own | `WardrikDaemon.Config.Orgs` |
| `roles`, `bindings` | Who may do what, in which org | `WardrikDaemon.Config.Access` |
| `models`, `workspace`, `storage` | Below | |

The daemon sets what it knows itself: a server's `transport` from its `command` or `url`, a
channel's `owner` from `orgs`, and `oauth`'s `page` from `base_url`. An MCP server takes
`credential` for `credential_name`, and its `timeout` in seconds.

An agent's model and tools use the API keys its owner sealed, then its org's. `deployment_keys` is
`true` unless set, so they then use the deployment's. Set it to `false` to have every org bring
its own.

Servers, OAuth apps and notify targets that orgs and people add as the daemon runs are kept apart
from `config.yaml`. They're added over the HTTP API, as `wardrik server add`, `wardrik provider
add` and `wardrik notify add` do. See `WardrikDaemon.Servers`, `WardrikDaemon.OAuthApps` and
`WardrikDaemon.NotifyTargets`.

A person signs in with the nearest OAuth app of a name: their own, their org's, then the
deployment's, from `oauth.providers`. Another org's app is never used. An added app's client
secret is named, as `wardrik provider add linear --secret LINEAR_SECRET`, and read from its
owner's vault, sealed `--for client_secret`, each time it's needed.

Their URLs must be `https` at a public address: loopback, private, link-local and cloud metadata
addresses are refused, as each is added and as each connection or notice is sent. Hosts
`config.yaml`'s OAuth providers name are trusted. For local development, with servers on your own
machine, set `allow_private_urls: true`. Never in production. See `WardrikDaemon.Egress`.

### models

Prices for models the catalog has no dollar price for, so budgets and spending count them. Give
`input` and `output`, and optionally `cache_read` and `cache_write`, in dollars per million
tokens. Or price it as another model with `priced_as`. Either takes a `markup`, as `0.1` for 10%
more.

```yaml
models:
  zai_coding_plan:glm-5.1: {priced_as: zai:glm-5.1}
  openrouter:qwen3-coder: {input: 0.3, output: 1.2}
```

### workspace

`workspace.shared` names the agents whose workspaces other agents may mount. Each lists, by name,
the agents that may `read` it and those that may `write` it. Names are of agents in one org:

```yaml
workspace:
  shared:
    runbooks:
      read: [triage]
      write: [ops]
```

An agent file mounts one by name: `workspace: {shared: {runbooks: runbooks}}`.

### notify

`notify.targets` names the targets agents' notices go to: a room of a channel, or a webhook.
`retries` and `req_options` are `Wardrik.Notify`'s. An agent file routes notices to a target, or
straight to a room:

```yaml
notify: {to: ["slack:#updates"], on: [finished, failed]}
```

### storage

`storage` keeps everything in Postgres. Point it at the primary. The daemon creates its table as
it starts, one node at a time. Without `storage`, everything is kept on the node's disk.

### orgs

`orgs` declares the orgs beside the deployment's own `org`. Each lists the servers, channels and
notify targets its agents use, by their names in those sections, and the policy in `policies/` it's
held to:

```yaml
org: platform

orgs:
  "*":                       # every org
    mcp: [search]
    policy: base
  payments:
    mcp: [stripe, github]
    channels: [payments-slack]
    notify: [audit]
    policy: payments-strict
  growth:
    mcp: [github]
```

* Every agent of an org is held to `"*"`'s policy, its org's policy, and its own definition's. The
  strictest decides. A definition can narrow them, never widen them.
* A policy's budget is the org's, a ceiling its agents spend from together. Each org spends `"*"`'s
  budget apart from the others. A budget per turn stays each agent's own.
* An org whose policy isn't in `policies/` runs none of its agents.
* A server, channel or target no entry lists is the deployment's own org's.
* A channel serves one org, or every org if `"*"` lists it.
* Any other org is refused: no agent or secret is kept for it.

Each org's agents reach a server with their own credential. Here, payments and growth each seal
their own `github`:

```sh
wardrik vault put github --org payments --for header
```

### roles and bindings

`roles` and `bindings` say who may do what, as Kubernetes RBAC does. A role's rules each allow
`verbs`, the part of an action after the dot, as `ask` for `agent.ask`, on `kinds` of resource:
`agent`, `secret` (an owner's secrets), `ceiling` (an org's ceilings), `mcp_server` and
`notify_target` (an owner's MCP servers and webhooks), `provider` (an owner's OAuth apps),
`connection` (a person's accounts), `deployment` or `token`, and, with `names`, only those: agents
by name, the rest by ID. Making an agent is `create` on `agent`. A binding gives a role to subjects
within one org:

```yaml
roles:
  reader: {rules: [{verbs: [read, events], kinds: [agent]}]}
  operator: {rules: [{verbs: ["*"], kinds: ["*"]}]}
bindings:
  - {org: payments, role: operator, subjects: [user:ana, group:payments-eng]}
  - {org: payments, role: reader, subjects: [agent:triage]}
```

* Subjects are `user:ID`, `group:NAME` or `agent:NAME`, the agent of that name in the binding's
  org. A token names its user and groups, or its agent by ID.
* An agent acting through its tools gets its own bindings, never its owner's.
* Everyone may do anything to what they own: `payments/@ana` to the agents she owns, and to her
  own secrets, servers, notify targets and OAuth apps.
* Everyone manages their own connections, the accounts they sign in to, and no one else's.
* A chat member acts as the user `channels.<name>.members` maps them to, so that user's bindings
  decide what they may ask, read and decide. They reach only the agents of the workspace's owner,
  and only to ask, read and decide. Whoever asked for a turn may always decide its calls. An
  unmapped member is refused, unless the channel sets `unmapped_members: allow`: then they act as
  `user:<channel>:<workspace>/<member>`.
* Outside the orgs their bindings name, people find nothing, not even that something's there. The
  deployment itself is in no org, nor are its secrets: only a binding in `"*"` reaches them.
* Tokens are in no org: only a binding in `"*"` on the `token` kind reaches them. Its `names` say
  which subjects a caller may make tokens for. Only the admin makes one for `user:admin`, whatever
  the bindings say.
* `operator` is every verb on every kind unless `roles` says otherwise. The deployment's admin,
  `user:admin`, which the `wardrik` command and the agent files act as, holds `admin`, every verb
  on every kind, in `"*"`.

### The HTTP API

The daemon serves Wardrik's operations (see `Wardrik.HTTP`), and its own routes beside them, each
taking the same tokens, roles and bindings. `priv/openapi.json` describes its own:

| Route | Serves |
| --- | --- |
| `POST /v1/owners/{owner}/agents` | makes an agent from its `name` and definition: mints its ID and defines it |
| `GET /v1/owners/{owner}/agents?name=` | the agents of the owner's org the caller may read, by name |
| `GET /v1/owners/{owner}/secrets` | the owner's secrets, by name and purpose, never a value |
| `PUT /v1/owners/{owner}/secrets/{name}` | seals one, as `{"value": ..., "purpose": "api_key"}` |
| `DELETE /v1/owners/{owner}/secrets/{name}` | removes one |
| `GET /v1/owners/{owner}/ceilings` | what an org's agents have spent against each ceiling |
| `GET`, `POST /v1/owners/{owner}/servers`, `DELETE .../servers/{name}` | the MCP servers the owner's agents reach; adds or removes one of their own |
| `GET`, `POST /v1/owners/{owner}/notify_targets`, `DELETE .../notify_targets/{name}` | the webhooks the owner's agents' notices reach; adds or removes one of their own |
| `GET`, `POST /v1/owners/{owner}/providers`, `DELETE .../providers/{name}` | the OAuth apps the owner's people sign in with; adds or removes one of their own |
| `GET /v1/connections`, `POST`, `DELETE /v1/connections/{provider}` | the caller's own accounts; starts a sign-in to one, answering its URL or device code; forgets one |
| `GET`, `POST /v1/tokens`, `DELETE /v1/tokens/{id}` | tokens: lists them, never a secret; makes one, showing its secret once; revokes one |

An owner is one path segment: `payments`, `payments%2F%40ana` or `deployment`. See
`WardrikDaemon.HTTP`.

## The wardrik command

`wardrik help` lists every command, and `wardrik help COMMAND` says more about one. Every command
takes `--json`.

| Command | Does |
| --- | --- |
| `init`, `doctor`, `version`, `completion SHELL` | sets up the front door and starts the daemon, checks what the daemon reads, prints the version, writes shell completion |
| `serve`, `start`, `stop`, `pid`, `logs` | runs the daemon in the foreground or background, stops it, prints its process id, follows its log |
| `service install`, `service uninstall` | runs it as a systemd user service, or stops doing so |
| `status`, `reload`, `audit` | says where it runs, reads the agent files again, shows what people changed |
| `agent ls` (`ls`), `agent show AGENT` | lists agents, shows one |
| `agent ask AGENT MESSAGE` (`ask`), `agent follow AGENT` (`follow`) | asks and prints the answer as it comes, follows what an agent does |
| `agent history`, `agent cancel`, `agent rm`, `agent calls`, `agent kill`, `agent move` | an agent's history, stopping its turn, removing it, its running tool calls, stopping one, moving it to another node |
| `approval ls`, `approval approve AGENT CALL`, `approval deny AGENT CALL` | the calls agents wait on a person for |
| `trigger ls`, `trigger set`, `trigger rm` | an agent's triggers |
| `server ls`, `server add`, `server rm` | MCP servers an owner adds |
| `notify ls`, `notify add`, `notify rm` | webhooks an owner adds for their agents' notices |
| `provider ls`, `provider add`, `provider rm` | OAuth apps an owner adds for their people |
| `connection ls`, `connection connect`, `connection disconnect` | your own accounts, as the token's user |
| `vault put`, `vault ls`, `vault rm` | secrets: the deployment's, or an org's or a person's with `--org` or `--user`, each sealed `--for` one purpose |
| `token create NAME --subject user:ana`, `token ls`, `token revoke ID` | tokens for everyone else, each acting as its subject and `--groups`, until it `--expires` |

An `AGENT` is a name: `triage` in the deployment's org, or `growth/triage` in another. Commands on
an agent take `--conversation ID` for one of its conversations, as a Slack thread's.

The command acts as the deployment's admin, with a token the daemon writes to `cli_token` in the
data home each time it starts. `WARDRIK_URL` and `WARDRIK_TOKEN` point it at another daemon. The
admin makes everyone else's with `wardrik token create`. `WardrikDaemon.Tokens` keeps only their
hashes.

## Directories

| Variable | Default | Holds |
| --- | --- | --- |
| `WARDRIK_CONFIG_DIR` | `~/.config/wardrik` | `config.yaml`, `agents/`, `policies/` and `env` |
| `WARDRIK_DATA_DIR` | `~/.local/share/wardrik/store` | the store |
| `WARDRIK_DATA_HOME` | `~/.local/share/wardrik` | `vault_key`, `cli_token` and the node's `cookie` |
| `WARDRIK_STATE_DIR` | `~/.local/state/wardrik` | logs |
| `WARDRIK_ENV_FILE` | `env` in the config directory | variables the daemon sets where its environment doesn't |
