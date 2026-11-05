# Changelog

## 0.1.0-rc.7 (2026-11-05)

- `storage: {s3: ...}` keeps everything in an S3 bucket: AWS, R2, Tigris or MinIO. Nodes don't wait
  for a quorum. `wardrik doctor` checks the endpoint answers.
- `cluster` in `config.yaml` runs several daemons as one: `nodes: [a, b, c]` on one machine, full
  names on several, or `dns` and `size`. `libcluster` connects them. The store on the nodes'
  disks counts its quorum over the cluster, and a node waits for one as it starts. See
  `WardrikDaemon.Cluster`.
- `serve`, `start`, `stop`, `pid`, `logs` and `service` take `--node`. `WARDRIK_NODE` names the
  node, `WARDRIK_DIST_INTERFACE` and `WARDRIK_DIST_EXPOSED` where distribution listens.
- Nodes on one machine share the HTTP API's port: the first to start listens, and another takes it
  over when that one stops.
- Nodes starting together give each agent file one agent, and share one cookie on a fresh install.
- `agents` in `config.yaml` spreads agents across nodes: each new agent, and each a lost node ran,
  starts on the node with the most room under `max_per_node`, `max_memory` and `max_cpu`. Idle
  agents compact their memory after `hibernate_after` seconds. Requires `wardrik` 0.1.0-rc.7.
- Builds on `wardrik_store` 0.1.0-rc.5 and `wardrik_events` 0.1.0-rc.5. Depends on `libcluster` 3.6.
  `mimic` 2.5 for tests.

## 0.1.0-rc.6 (2026-11-04)

- Fixes `trigger rm`, event log trimming and removing OAuth grants failing with
  `:cas_managed_key`. Builds on `wardrik_store` 0.1.0-rc.4.
- Requires `wardrik` 0.1.0-rc.6.
- `wardrik uninstall` removes what install.sh installed. `--purge` also deletes the config, keys
  and store.
- `wardrik init` says when another Wardrik is running here, and how to use it or replace it. When
  the daemon doesn't answer, it shows the end of its log, and it ends with its next steps in a box.

### At a terminal

- `wardrik ask` asks about each call the turn waits on, and goes on once it's decided. Before
  sending, it asks about calls the agent already waits on, since the message waits behind them.
- `wardrik ask` and `wardrik agent follow` show what the turn does on a line that redraws in
  place, `⠋ web_search · 12s`, ending as `✔ 14s · 3 tool calls` or `? waits on you after 6s`.
- `wardrik agent follow` shows what the agent already waits on, and asks about each call.
- `wardrik approval` goes through every call waiting on a person; Enter skips one.
- A command that reaches the daemon ends by saying what waits on you:
  `1 call waits on you: wardrik approval approve triage call_1`.
- `wardrik ask AGENT` with no message opens `$VISUAL` or `$EDITOR` to write it.
- `wardrik vault put` asks for the value, not shown as it's typed.
- `init`, `doctor`, `reload` and `connection connect` show a spinner while they wait. `doctor`
  and `agent ls` use colour, and reasoning is set off by a blank line before and after it.
- Hints name each call: `wardrik approval approve triage call_1`.

## 0.1.0-rc.5 (2026-11-04)

- Fixes every turn failing with `unknown options [:finch_name]`.
- Streamed turns use up to 64 connections per provider host, up from 8.
- Requires `wardrik` 0.1.0-rc.5.

### Breaking

- `config.yaml`'s `models.pool` is gone. Model calls use `ReqLLM`'s own connection pool.

## 0.1.0-rc.4 (2026-11-04)

- Every model call goes through a `WardrikGateway`: a circuit breaker per model, and the fallbacks
  and limits set in `config.yaml`'s `models.gateway`.
- `wardrik trigger set --overlap` takes `settle`.
- A Slack notice for a turn in a thread isn't posted; the thread shows it.
- Requires `wardrik` 0.1.0-rc.4, `wardrik_gateway` 0.1.0-rc.1 and `wardrik_slack` 0.1.0-rc.3.

### Breaking

- `config.yaml`'s `models` holds `prices` (the former `models`), `options` for every model call
  as `ReqLLM` takes them, `pool` for connections per provider host, and `gateway`.

## 0.1.0-rc.3 (2026-11-03)

- Runs on Wardrik 0.1.0-rc.3. A daemon starts beside another on the same store, as in a blue-green
  deploy; each tells of the agents it runs.
- Model calls wait up to five minutes, as Wardrik sets them; the daemon no longer sets req_llm's
  timeouts.

## 0.1.0-rc.2 (2026-11-02)

- `config.yaml` is checked against each library's own options. Errors name the YAML path:
  `config.yaml: oauth.providers.google: unknown options [:colour], valid options are: [...]`.
- New `config.yaml` keys: `deployment_keys`, `allow_private_urls`, `deployment`, `idle_timeout`,
  `retention`, `triggers`; `oauth.client_name`, `oauth.req_options` and a provider's
  `authorization_params`; a channel's `offering`, `deciding`, `req_options`, `members` and
  `unmapped_members`; `notify.retries` and a webhook's `req_options`; an MCP server's `cost`.
- `roles` and `bindings` decide who may do what, in which org, as Kubernetes RBAC does. See
  `WardrikDaemon.Config.Access` and `WardrikDaemon.Authorizer`.
- A channel's `members` maps chat members to users. `unmapped_members: allow` lets the others act
  as `user:<channel>:<workspace>/<member>`. See `WardrikDaemon.ChannelMembers`.
- The daemon mints agent IDs (`agt_` and a ULID) and keeps each agent's org, owner and name.
  `POST /v1/owners/{owner}/agents` makes an agent; `GET /v1/owners/{owner}/agents?name=` finds one.
- The `agent_create` tool makes a worker in the agent's org. `wardrik init` gives it to the
  assistant, with a `workers` role.
- Tokens are the daemon's own: `wardrik token create`, `token ls` and `token revoke`, and
  `/v1/tokens`. See `WardrikDaemon.Tokens`.
- Secrets and ceilings have their own routes: `/v1/owners/{owner}/secrets` and
  `/v1/owners/{owner}/ceilings`. An org's policy budget is shared by its agents. See
  `WardrikDaemon.Keys` and `WardrikDaemon.Ceiling`. Reaching a ceiling emits the telemetry event
  `[:wardrik_daemon, :ceiling, :reached]`, not a `wardrik.ceiling.reached` event in the log.
- Orgs and people add MCP servers, webhooks and OAuth apps while the daemon runs:
  `wardrik server`, `wardrik notify` and `wardrik provider`, and their routes. The nearest of a
  name wins. Their URLs must be `https` at a public address unless `allow_private_urls: true`.
- Your own accounts: `wardrik connection ls`, `connect`, `pair` and `disconnect`, and
  `/v1/connections`. A browser sign-in finishes with the code its page shows. See
  `WardrikDaemon.Pairings`. `DELETE /v1/connections/{provider}` answers `204`, or `404` where
  you hold no such account.
- `connections.list` entries carry `signing_in`. `wardrik connection connect` stops waiting as soon
  as a device sign-in is granted, declined or expired.
- Commands on an agent take `--conversation ID`. `approval ls` shows each call's conversation.
- A channel posts an agent's notices in the workspace its owner added the channel to.
- A reload restarts the daemon when `config.yaml` or `policies/` changed.

### Breaking

- Agent IDs are minted by the daemon. `agent.define` refuses any other ID.
- An agent file's name is its agent's name. It takes `org` and `owner`, not `name` and `user`.
- `config.yaml` and the `wardrik` command name agents by name, as `triage` or `growth/triage`.
  A binding in `"*"` can't name an agent.
- `token create` takes `--subject`, `--groups` and `--expires`.
- `vault put` takes `--for`: `api_key`, `client_secret`, `header` or `signing_secret`.
- `reload` and `agent cancel` take names, not patterns.
- `connection` commands act on your own accounts and take no `--org` or `--user`.
- A browser sign-in's callback page connects nothing. It shows a code to finish the sign-in.
- `workspace.shared`, in `config.yaml` and in agent definitions, names agents as `agent:NAME`,
  exactly, no patterns.
- A user's ID is their owner, as `user:acme/@ana`. Bindings, tokens and a channel's `members`
  refuse other users, `user:admin` aside. `wardrik ls user:` takes the same.
- Removing a secret, MCP server, webhook, OAuth app, connection or token needs the `delete` verb.
  Revoking a token was `revoke`.
- `notify`'s targets go in `notify.targets`. `notify.req_options` is gone; a webhook takes its own.
- `channels.*.approvers`, `channels.*.admins` and `create`, `mcp.*.cwd`, and `oauth.client` and
  `redirect` are gone.
- Agent files are defined as the deployment's admin.
- `WardrikDaemon.Capabilities.all` takes the daemon's store as a second argument.

## 0.1.0-rc.1 (2026-10-30)

- The daemon: Wardrik on the node's disk or in Postgres, the HTTP API, and the channels
  `config.yaml` names.
- `config.yaml`: org, base URL, defaults, models, MCP servers, OAuth providers, channels, notify
  targets, orgs, storage, the vault's keys and where HTTP listens. `${NAME}` reads the environment,
  the env file or the vault.
- Agents from Markdown files in `agents/`, and policies from `policies/`, read again on reload.
  `defaults` apply to every agent.
- `wardrik init`, which sets up the front door: `assistant.md`, an agent that works with the org's
  agents, with a playbook to edit.
- The `wardrik` command over the HTTP API: ask with the answer streamed, agents, approvals,
  triggers, servers, connections, tokens, the vault and the audit.
- `serve`, `start`, `stop`, `logs` and `service install` in the release's script, and
  `wardrik doctor`, which checks what the daemon reads.
- Tools agents may name: `files` over a workspace of their own, `run_lua` in a sealed sandbox,
  `web_search` through Brave, and `deep_research`.
- An installer for Linux, x86_64 or aarch64, checked against `SHA256SUMS`, and an image for
  elsewhere.
