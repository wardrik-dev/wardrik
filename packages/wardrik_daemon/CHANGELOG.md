# Changelog

## Unreleased

- Notify targets are Wardrik's `notify_targets.*` operations, sent by
  `Wardrik.Notify.OwnedWebhook`. `notify_targets.list` lists the owner's own.
- Connections are Wardrik's `connections.*` operations. The daemon keeps `connections.pair`,
  which pairs a browser sign-in as its callback comes, whoever started it.
- MCP servers are Wardrik's `servers.*` operations. `servers.list` lists the owner's own. An
  agent reaches its owner's server of each name, else its org's, else the deployment's, as
  `WardrikDaemon.Authorizer` allows `mcp_server.use`. A server runs as its reference, as
  `acme%2F%40jon:crm` for a person's.
- OAuth apps are Wardrik's `providers.*` operations. `providers.list` lists the owner's own.
  A person signs in with their own app of a name, else their org's, else the deployment's, as
  `WardrikDaemon.Authorizer` allows `provider.use`. Connected accounts are kept by the app's
  reference, as `acme:linear`, so each is connected again once.
- Secrets are Wardrik's `secrets.*` operations. An owner the daemon doesn't know answers
  `not_found`, from `WardrikDaemon.Authorizer`, where it answered `invalid_request`.
- A sign-in an agent asked for, while waiting on it, finishes from the browser like one
  `wardrik connection connect` started: its page shows the code to pair. It showed "Sign-in not
  found" before.
- `wardrik trigger set --at 2026-11-17T09:00` runs a trigger once, then removes it. `trigger set`
  says when the trigger runs next, and `trigger ls` shows `once at`.
- `wardrik doctor` fails for each agent whose saved state the running daemon can't read, and
  says why. `wardrik reload` starts such agents over and says so. `wardrik ls` shows them as
  `unreadable`, `attention` includes them, and `wardrik agent show` gives the reason.
- `rest` in `config.yaml`: HTTP APIs from their Google Discovery documents, each a tool group of
  its name, with sign-in from `oauth` and keys from the vault. Orgs list them as `rest`. Each
  takes `max_schema_bytes` and `argument_headers`. An API's description is a Discovery document
  (`discovery`) or an OpenAPI 3 one in JSON or YAML (`openapi`), and `schemes` adds the schemes
  it doesn't name.

## 0.1.0-rc.12 (2026-11-12)

- Requires `wardrik` 0.1.0-rc.11 and `wardrik_slack` 0.1.0-rc.5.
- Releases are in wardrik-dev/wardrik, tagged `wardrik_daemon-v<version>`. `install.sh` reads
  them there.

## 0.1.0-rc.11 (2026-11-11)

- Requires `wardrik` 0.1.0-rc.10 and `wardrik_brave` 0.1.0-rc.3.
- The assistant `init` writes checks how things run every 6 hours, not each hour, and names the
  five reads it uses in place of `ops/read`. Each check is a model call with its tools.
- `secret_request` says what each purpose is for: `header` for an MCP server's token. The
  assistant asks for a secret before adding what uses it.
- `web_search`'s help names `wardrik vault put BRAVE_API_KEY --for api_key`. A key in the
  environment counts only when `config.yaml` names it.
- `wardrik doctor` says a key sealed in the vault works for `web_search`, which it can't see.
- The assistant says how to change an agent a file declares, and names `wardrik approval approve`.
- The assistant's `observer` role lists the deployment's secrets by name, so it sees a key
  sealed for the deployment before saying one is missing.
- `wardrik agent files ls`, `cat`, `put`, `rm` and `sync` manage an agent's files from the
  command line. `sync AGENT DIR --to skills` writes the files of a directory that differ, and
  with `--delete` deletes those under the prefix that the directory doesn't have.
- The `help` tools answer how Wardrik works and where this deployment keeps things:
  `wardrik_about` for the version, URLs and files, `docs_search` and `docs_read` for the
  documentation, and `wardrik_doctor` for the doctor's checks. See `WardrikDaemon.HelpTools`.
- The `settings` tools list an owner's MCP servers, notify targets, OAuth apps and secret names,
  and add servers, notify targets and OAuth apps once a person approves. `secret_request` hands
  a person the page and command that seal a secret. See `WardrikDaemon.SettingsTools`.
- `wardrik init`'s assistant gets `ops/read`, `settings`, `help` and `web_search`, with a role to
  read its org's runs and settings and add settings, and an `observer` role over the deployment's
  nodes, resource use and audit. Its instructions cover finding out what went wrong, setting
  things up, and questions about Wardrik. Each hour its `check` trigger looks at its workers'
  runs, waiting calls, the doctor's checks and node memory, and proposes what needs a person as a
  call that waits for approval.
- `wardrik doctor` names the tools an older `assistant.md` leaves out.
- A binding in `org: deployment` reaches the deployment's own resources, tokens aside, and may
  name an agent of the deployment's own org.
- `web_search` says how to give it a Brave key while it has none.
- Server's `:capabilities` adds tools to the daemon's own, where it replaced them.

## 0.1.0-rc.10 (2026-11-11)

- Requires `wardrik` 0.1.0-rc.9 and `wardrik_web` 0.1.0-rc.1.
- The daemon serves the web dashboard at `/web`, on the HTTP API's port. `wardrik web` prints a
  sign-in link that works for two minutes. The session lasts 12 hours. `web.enabled: false` turns
  the dashboard off.
- The dashboard shows agents, approvals, the audit, nodes and their resource use, and runs any
  operation. Its settings pages add and remove MCP servers, secrets, notify targets and OAuth
  apps, and connect your accounts. It also shows ceilings, tokens and the configuration.
- `POST /v1/tokens/web` returns a sign-in link for the user the token acts as.

## 0.1.0-rc.9 (2026-11-06)

- Requires `wardrik` 0.1.0-rc.8 and `wardrik_acp` 0.1.0-rc.1.
- `harnesses` in `config.yaml` names coding agents that speak ACP, such as Claude Code. Each is a
  tool of the same name, so an agent file lists `tools: [claude]`. See `WardrikACP`.
- `checkouts` names the git repositories they work in, as a path or `{path, base, fetch}`. New
  work starts from `base` in a worktree in the data directory's `worktrees`. A daily sweep removes
  each worktree whose work is in `base`.
- `orgs.<org>.harnesses` gives a harness to an org. A harness no org lists is the deployment's
  org's.
- `wardrik doctor` checks each harness's command is on `PATH`, and each checkout has its `base`.
- The approval card shows the arguments of the call a person decides on, from the interrupt. For
  a coding agent's request, that is the request's, not the task's. `wardrik approval` shows them
  too.

## 0.1.0-rc.8 (2026-11-06)

- `domains` on a channel maps an email domain to an org: a Slack member whose address is
  `ana@acme.com` acts as `user:acme/@ana`. `members` still maps one member, and wins.

### Breaking

- `unmapped_members` is gone, and with it the `user:slack:T0123/U024BE7LH` users. Map the
  domain instead.
- The Slack app needs the `users:read.email` scope. Add it to the manifest and reinstall.

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
