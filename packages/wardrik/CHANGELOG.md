# Changelog

## Unreleased

- A saved state this release can't read is never replaced quietly. The agent's status is
  `unreadable` with the reason, such as the modules it names that the release doesn't have, and
  messages to it return a `conflict` error. `agent.define` starts it over and answers `reset`.
  `Wardrik.Store.Durable` warns once for each such state, not each discovery round.
- In development, a module a saved state names is loaded before the state is called unreadable.

## 0.1.0-rc.11 (2026-11-12)

- Requires `wardrik_core` 0.1.0-rc.6 and `wardrik_protocol` 0.1.0-rc.7.
- Takes in `wardrik_store`, `wardrik_events`, `wardrik_policy`, `wardrik_vault`, `wardrik_oauth`,
  `wardrik_mcp`, `wardrik_triggers`, `wardrik_workspace`, `wardrik_http`, `wardrik_channel` and
  `wardrik_testing`. Their modules are renamed: `WardrikStore` is `Wardrik.Store`, and the same
  for `Policy`, `Vault`, `OAuth`, `MCP`, `Triggers` and `Workspace`. `WardrikEvents` is
  `Wardrik.EventLog`, `WardrikChannel` is `Wardrik.Chat`, `WardrikHTTP` is
  `Wardrik.HTTP.Endpoint`, and `WardrikTesting` is `Wardrik.Testing`. Telemetry events and
  stored data are unchanged.
- `Wardrik.Workspaces` is `Wardrik.Workspace.Agents`.
- One `Wardrik.Sink` and one `Wardrik.Listener`, both given `%Wardrik.Event{}`. The event log's
  own `Sink` and `Listener` are gone.
- Exceptions end in `Error`: `Wardrik.MCP.UnavailableError`, `Wardrik.Workers.UnavailableError`
  and `Wardrik.Workers.LostError`.

## 0.1.0-rc.10 (2026-11-11)

- Requires `wardrik_core` 0.1.0-rc.6 and `wardrik_protocol` 0.1.0-rc.7.
- An agent with the `files` tool writes a digest of each conversation to
  `digests/<conversation>.md` before it sleeps, with its own model. `digest: false` turns it off.
  It counts towards the agent's budget, and keeps the labels of what it read. See
  `Wardrik.Digest`.
- `ops/ID` names a read too, as `ops/agent.runs`, so an agent gets only the reads it needs. Each
  tool goes into every model call.
- `agents_list` marks an agent a file declares with `"file": true`, and `agent_define` says that
  a person changes it by editing its file.
- `agent.files`, `agent.file`, `agent.file_put` and `agent.file_delete` let people and apps
  manage an agent's files, such as skills, runbooks and `MEMORY.md`. Files written this way carry
  no labels. Roles grant them as the verbs `files`, `file_put` and `file_delete`. They're never
  `ops/*` tools: agents use workspace mounts.
- `ops/read` in an agent's `tools` gives it every operation that only reads: runs, the timeline,
  running calls, what it gets from its owner, approvals waiting, the audit, nodes and resource
  use. `ops/ID`, such as `ops/agent.stop`, gives one operation that changes something; it asks
  a person unless the policy allows it. Approving and denying calls are never tools. See
  `Wardrik.OperationTools`.

## 0.1.0-rc.9 (2026-11-11)

- Requires `wardrik_core` 0.1.0-rc.5 and `wardrik_protocol` 0.1.0-rc.6.
- `deployment.runtime` returns resource use for each node and the running agents that use the
  most memory. `agent.runtime` returns one running agent's memory, mailbox size, process count and
  reductions. An agent's figures include its current turn and its running tool calls. Each
  node also reports the memory the OS gives it (on Linux), persistent-term memory, and its
  processes grouped by the module that runs them. `deployment.nodes` counts the running, idle and
  parked agents.
- `agent.resolved` returns what the resolver gives an agent: who it works for, its policies, MCP
  servers and the tools each offers now, notify targets, channels and workspaces. Notify targets
  your app delivers itself are listed by name only.

## 0.1.0-rc.8 (2026-11-06)

- Requires `wardrik_protocol` 0.1.0-rc.5, `wardrik_events` 0.1.0-rc.6, `wardrik_policy`
  0.1.0-rc.3 and `wardrik_channel` 0.1.0-rc.5.
- A notice's calls take their arguments from the interrupt. `Wardrik.Notify` no longer follows `tool_call.started`.

## 0.1.0-rc.7 (2026-11-05)

- `:agents` spreads agents across nodes: each new agent, and each agent a lost node ran, starts on
  the node with the most room under `max_per_node`, `max_memory` and `max_cpu`. Idle agents
  compact their memory after `hibernate_after` seconds.
- Locks wardrik_core, wardrik_protocol, wardrik_store, wardrik_events, wardrik_triggers and
  wardrik_channel at their latest, and ecto 3.14.3 for EEF-CVE-2026-118391.
- Defining an agent another node is starting at the same moment takes the one that node started.
  It failed with `didn't start: {:already_started, pid}`.

## 0.1.0-rc.6 (2026-11-04)

### Breaking

- `:pool` is gone. Model calls use `ReqLLM`'s own connection pool, sized by
  `config :req_llm, stream_pool_size:`.

## 0.1.0-rc.5 (2026-11-04)

- Fixes every streamed turn failing with `unknown options [:finch_name]`. Wardrik no longer passes
  `finch_name`, which `ReqLLM` refuses when it builds a stream.
- `:pool` serves model calls that don't stream. Turns stream through `ReqLLM`'s own pool, sized by
  `config :req_llm, stream_pool_size:`.

## 0.1.0-rc.4 (2026-11-04)

- Triggers with `overlap: settle`, the default except for webhooks, cancel a turn waiting on an
  unanswered interrupt, then send their prompt. The cancel is recorded as `agent.cancelled` with
  the trigger's name.
- `:model_options` sets `ReqLLM` options for every agent's model calls. A definition's
  `model_options` are merged over them and take only `temperature`, `top_p`, `max_tokens`,
  `reasoning_effort` and the call's timeouts.
- Each Wardrik starts its own `Finch` pool for model calls, set by `:pool`: 64 HTTP/1 connections
  per provider host by default, up from `ReqLLM`'s 8.
- Requires `wardrik_core`, `wardrik_protocol` and `wardrik_triggers` 0.1.0-rc.4.

## 0.1.0-rc.3 (2026-11-03)

- A model call waits up to five minutes for an answer, and as long on a stream gone quiet, so a
  model that thinks for minutes isn't cut off; your app no longer sets req_llm's timeouts.
- `sinks:` sends every kept event, agents' and the audit's, to each `Wardrik.Sink`: to ship events
  to a warehouse, a queue or tracing.
- Each node tells of the agents it runs, from a sink. Nodes that share a store without being
  clustered, as the old and new releases of a blue-green deploy do, start beside each other. A
  notice is sent at most once: one whose node stops first is lost, though the agent's interrupts
  still list what waits.
- `agents.list` reads what every agent shares in one pass, not once per agent: 10,000 agents on
  Postgres list in about 0.2s, down from 5.7s. `interrupts.list` takes about 0.05s, down from 1.6s.
- `agents.list` takes `limit` and `after`, and answers `next`. Without `limit`, it lists every
  agent.
- `Wardrik.Views.Timeline` and `Wardrik.Views.Runs` fold an agent's events, as `Wardrik.Event`s or
  JSON, into its conversation and its runs, and keep them current as events arrive.
- `agent.timeline` gives each task handed to a delegate a `subagent` step, with what it
  answered; what the delegate says and does no longer reads as the agent's answer.

### Breaking

- `events.list` and `events.head` read only the agents named: `agents` is required. Reading every
  agent's log from a cursor is gone; use a sink.
- `Wardrik.Listener` takes `:agents`, required. To take every agent's events, use a sink.

## 0.1.0-rc.2 (2026-11-02)

- `Wardrik.Resolver` says what each agent gets, as a `Wardrik.Resolved`: who it works for, its
  policy, defaults, middleware, MCP servers, notify targets, channel workspaces and shared
  workspaces. An agent reaches only what it's given.
- `Wardrik.refresh/2` applies what awake agents now resolve to, for every agent or `agents:`.
- `Wardrik.schema/0` returns `Wardrik.start_link/1`'s options as a NimbleOptions schema.
- `:credentials`, `:key_source` and `:grants` options say where credentials, API keys and OAuth
  grants come from.
- A resolver can give an agent a notify target of its own, as `{module, opts}`. Each target's
  options are checked against `c:Wardrik.Notify.schema/0`.
- `Wardrik.Channels.owned/2` lists a channel's installations for an owner your app names.
- `agents_list` gives each agent's `description`.
- `Wardrik.mcp/1` takes the instance's name or struct.
- MCP servers' header secrets are `{:secret, name}`, read as each connection starts.
- A vault secret is read only for its kind, as `:header` or `:signing_secret`.
- `sign_in/3`, `signing_in?/3` and `forget_client/2` start and follow sign-ins from your app.
- A reply's interrupts name their `agent` and `conversation`. Pass one to `approve/2` or `deny/2`
  as `interrupt:`.

### Breaking

- `:keys` is `:vault_keys`, so it isn't mistaken for `:key_source`.
- A `:key_source` returns `{:error, :not_found}` for no key, not `:error`.
- A `WardrikOAuth.Resolver` builds each provider with its `:key`:
  `WardrikOAuth.Provider.new("github", key: "github", ...)`.
- `Wardrik.Agent.decide/2` takes one keyword list: `agent:`, `decisions:` and `conversation:`.
- `:authorizer` and `:resolver` are required.
- `c:Wardrik.Authorizer.authorize/2` takes a `Wardrik.Authorizer.Request`. Resources are
  `{:agent, id}` and `{:deployment, name}`. The request names the `actor` beside the principal.
- `c:Wardrik.Resolver.resolve/2` takes a `Wardrik.Resolver.Request`.
- `Wardrik.as/3` takes `:actor` and `:context`. Agent tools and agents' answers act for the
  agent's resolved principal, with `actor: {:agent, id}`.
- Wardrik keeps no permissions, pooled budgets, API keys or secrets of its own. Your authorizer,
  resolver, `:credentials` and `:key_source` provide them.
- Agent IDs are your app's opaque text. Wardrik never parses them, and agents have no `name`.
- Conversations are a field, not part of the ID. Events carry `agent` and `conversation`, and
  `Wardrik.cursor/1` takes `%{{agent, conversation} => sequence}`.
- Operations on one agent take `conversation:` in their options:
  `Wardrik.Agent.ask(scope, "agt_1", "Hi", conversation: "C1")`. Operations with two or more path
  parameters take one keyword list:
  `Wardrik.Agent.approve(scope, agent: "agt_1", interrupt: "call_1", conversation: "C1")`.
- `agents:` filters and a listener's `:agents` take exact agent IDs, each with its conversations.
- A definition's `workspace.shared` mounts other agents' workspaces by agent ID, as the resolver
  shares them. An agent's own tree is `agents/<URL-encoded id>`.
- `Wardrik.Notify.Room` posts in the workspace the resolver gives for its channel, or skips.
- A trigger's `${NAME}` secret is the agent's resolved principal's.
- `:oauth` requires `:resolver`, a `WardrikOAuth.Resolver`.
- `finish_sign_in/3` takes `as:`. `sign_in_pages/2` and `Wardrik.HTTP`'s `:principal` say who is
  at the browser. Without them, no sign-in finishes.
- `Wardrik.start_link/1` raises `NimbleOptions.ValidationError` on a bad option.
- A worker's call `meta` gives `"agent"` as the agent's ID, not `%{"key" => id}`.
- `Wardrik.Channels` functions take keyword lists: `:channel`, then `:owner` and `:query`, or
  `:workspace`.
- `Wardrik.Delegation.asked/2` takes `:asker`, `:agent` and `:message`.
- A channel's `request/2` and `notify/2` take the request first.

### Upgrading from rc.1

Wardrik no longer knows about users, orgs, owners, tokens or secrets. Your app does, and Wardrik
asks it through modules you pass in.

Required now:

| Option | Behaviour | What it answers | In `wardrik_daemon` |
| --- | --- | --- | --- |
| `authorizer:` | `Wardrik.Authorizer` | May this request run? | `WardrikDaemon.Authorizer` |
| `resolver:` | `Wardrik.Resolver` | What does this agent get? | `WardrikDaemon.Resolver` |
| `oauth: [resolver: ...]` | `WardrikOAuth.Resolver` | Which OAuth app does this user sign in with? | `WardrikDaemon.OAuthApps` |
| `identities:` (each channel) | `WardrikChannel.Identities` | Who is this chat member? | `WardrikDaemon.ChannelMembers` |
| `Wardrik.HTTP`'s `authenticator:` | `WardrikHTTP.Authenticator` | Who sent this request? | `WardrikDaemon.Authenticator` |

Optional:

| Option | Behaviour | Default | In `wardrik_daemon` |
| --- | --- | --- | --- |
| `key_source:` | `WardrikCore.Keys` | none; ReqLLM reads its config and env | `WardrikDaemon.Keys` |
| `credentials:` | `WardrikCore.Credentials` | Wardrik's vault, with `:vault_keys` | the default |

Moved to your app (the daemon's versions in brackets):

- Tokens and grants: `Wardrik.Statement`, `grant/2`, `tokens.*` (`WardrikDaemon.Tokens`,
  `/v1/tokens`).
- Orgs, settings and ceilings: `Wardrik.Orgs`, `Wardrik.OrgSettings`, `Wardrik.Ceiling`
  (`WardrikDaemon.Orgs`, `WardrikDaemon.Ceiling`).
- Secrets and API keys: `put_secret/2` and friends, `secrets.*`, `Wardrik.Keys`
  (`WardrikDaemon.Secrets`, `WardrikDaemon.Keys`, `/v1/owners/{owner}/secrets`).
- OAuth apps and connected accounts: `providers.*`, `connections.*`
  (`WardrikDaemon.OAuthApps`, `WardrikDaemon.Connections`, `/v1/connections`).
- MCP servers and notify targets people add: `mcp_servers.*`, `notify_targets.*`
  (`WardrikDaemon.Servers`, `WardrikDaemon.NotifyTargets`).
- Agent names and owners: `Wardrik.AgentID`. Agent IDs are opaque. The daemon mints `agt_` IDs
  and keeps names in `WardrikDaemon.AgentRecords`.

Call sites:

- Conversations are an option, not an ID suffix:
  `Wardrik.Agent.ask(scope, "agt_1", "Hi", conversation: "C1")`.
- Two IDs go in one keyword list:
  `Wardrik.Agent.approve(scope, agent: "agt_1", interrupt: "call_1", conversation: "C1")`.
  So does `decide/2`: `Wardrik.Agent.decide(scope, agent: "agt_1", decisions: decisions)`.
- `keys:` is `vault_keys:`.
- `WardrikCore.Keys` returns `{:error, :not_found}` where it returned `:error`.
- Pass `key:` to `WardrikOAuth.Provider.new/2`, not `%{provider | key: key}`.
- Start a sign-in with `Wardrik.sign_in/3`, not `WardrikOAuth.authorize/3`.
- `Wardrik.as(instance, principal, actor: ..., context: ...)` replaces statements.
- Behaviour callbacks take one request struct, then options.
- A tool worker reads the calling agent's ID as `_meta.agent`, a string.

## 0.1.0-rc.1 (2026-10-30)

- `use Wardrik`: one module in your supervision tree that runs agents, keeps them in a
  `WardrikStore`, and holds them to a deployment-wide policy.
- Agents defined as data: model, instructions, tools, policy and triggers. Ask them, stream their
  answers, or wait for a `Wardrik.Reply`.
- Policies held at once by the deployment and each agent: rules that allow, ask or deny, budgets
  per agent, and ceilings per org.
- Approvals, for the people you choose to decide the calls agents wait on.
- Scopes that act as a person, with grants, roles, API tokens and your own authorizer.
- MCP servers Wardrik starts with, and servers an org or person adds as it runs. Credentials sealed
  at rest, and sign-ins that give agents people's accounts.
- Every operation as a function that takes and answers structs. Events and an audit to follow into
  your app.
- Guides for each, and Livebook notebooks that show them in action.
