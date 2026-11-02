# Changelog

## 0.1.0-rc.2 (2026-10-31)

- The events `wardrik.provider.added`, `wardrik.provider.removed`,
  `wardrik.notify_target.added` and `wardrik.notify_target.removed`, which `wardrik_daemon`
  records as an org or person adds or removes an OAuth app or a webhook.

### Breaking

- Every behaviour's callbacks take a request struct, then their options:
  `Wardrik.Server`'s `run/1` and `stream/1` a `Wardrik.Server.Request`, and `follow/2` a
  `Wardrik.Server.Follow`; `Wardrik.Channel`'s `request/2` the request, then the options, and
  `notify/2` a `Wardrik.Channel.Notification`; `Wardrik.Channel.Installations`' callbacks a
  `Wardrik.Channel.Installations.Request`, or the installation to `put/2`.
- Secrets and ceilings are `wardrik_daemon`'s own routes: `secrets.list`, `secrets.put`,
  `secrets.delete` and `ceilings.list`, `Wardrik.Secrets`, `Wardrik.Ceilings`, `Wardrik.Secret`,
  `Wardrik.Spend`, `Wardrik.Amount`, and the schemas `secrets`, `secret_input`, `ceilings` and
  `defs`' `amount` are gone.
- MCP servers and notify targets that orgs and people add are `wardrik_daemon`'s own routes:
  `mcp_servers.*` and `notify_targets.*`, `Wardrik.MCPServers`, `Wardrik.NotifyTargets`,
  `Wardrik.MCPServer`, `Wardrik.MCPServerAdded`, `Wardrik.NotifyTarget`, and the schemas
  `server_input`, `server_added`, `server`, `servers`, `notify_target_input`, `notify_target` and
  `notify_targets` are gone.
- OAuth apps and connections are `wardrik_daemon`'s own routes: `providers.*` and
  `connections.*`, `Wardrik.Providers`, `Wardrik.Connections`, `Wardrik.Provider`,
  `Wardrik.Connection`, `Wardrik.Connecting`, the schemas `provider_input`, `provider`,
  `providers`, `connection`, `connections` and `connecting` are gone. No operation's `subject`
  is `"owner"`.
- `Wardrik.AgentID.parse/1` refuses `@` in an owner beyond a person's leading one, so an ID like
  `ac@me/triage` or `acme/@jon` is `:error`.
- No tenancy: `Wardrik.Resource`, `Wardrik.Definition.principal/1`,
  `Wardrik.Channel.Installation`'s `approvers` and `agents/1`, and
  `Wardrik.Channel.Notification`'s `approvers` are gone. A notification names the `workspace` to
  post in. An agent definition's `workspace.shared` mounts other agents' workspaces, each by
  `agent` ID.
- No grants or tokens: `Wardrik.Statement`, `Wardrik.Tokens`, `Wardrik.Token`, the `tokens.*`
  operations and their schemas, `c:Wardrik.Server.authenticate/2`, and `Wardrik.Resource`'s
  `agent/1` and `owned/2` are gone. `Wardrik.Scope.new/2` takes the server, then `:wardrik`,
  `:principal`, `:actor` and `:context` by name. `agents.list`, `agents.forget`,
  `agents.cancel`, `interrupts.list`, `events.list`, `events.head` and `deployment.reload` take
  `agents`, exact agent IDs, for `resources`.
- An operation's function with two or more path parameters takes them by name in its input, as
  `Wardrik.Agent.approve(scope, agent: "acme/books", interrupt: "call_1")`: `Wardrik.Agent`'s
  `approve/2`, `deny/2`, `kill/2`, `authorization/2`, `trigger_set/2` and `trigger_remove/2`,
  `Wardrik.Hook.deliver/2` and `deliver_with_secret/2`, and `Wardrik.Channel.deliver/2`.

## 0.1.0-rc.1 (2026-10-30)

- Wardrik's events as CloudEvents: a JSON Schema for each event type, and for the envelope.
- Every operation in one OpenAPI 3.1 document, by its `operationId`, with the action it needs, its
  effect and what it acts on.
- `WardrikProtocol.schema/1`, a schema with every `$ref` inlined, for any JSON Schema validator.
- `operations/0` and `operation/1`, each operation with one `input` schema across its path, query
  and body.
- `types/0` and `dataschema/1`, for every event type.
- Live events, like `message.delta`, marked `x-wardrik-live`: sent as they happen, never stored.
- The typed Elixir functions, like `Wardrik.Agent.ask/3`, that packages built on Wardrik call.
- `Wardrik.Server`, the behaviour for what runs Wardrik's operations.
