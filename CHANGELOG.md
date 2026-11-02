# Changelog

## 0.1.0-rc.2 (2026-11-02)

- The events `wardrik.provider.added`, `wardrik.provider.removed`,
  `wardrik.notify_target.added` and `wardrik.notify_target.removed`.
- Each generated operation function's doc shows a call.

### Breaking

- Behaviour callbacks take a request struct, then options. `Wardrik.Server`'s `run/1` and
  `stream/1` take a `Wardrik.Server.Request`, and `follow/2` a `Wardrik.Server.Follow`.
  `c:Wardrik.Channel.notify/2` takes a `Wardrik.Channel.Notification`.
  `Wardrik.Channel.Installations` callbacks take a `Wardrik.Channel.Installations.Request`.
- Secrets, ceilings, MCP servers and connections are no longer protocol operations.
  `Wardrik.Secrets`, `Wardrik.Ceilings`, `Wardrik.MCPServers`, `Wardrik.Connections` and their
  types and schemas are gone.
- Statements and tokens are gone: `Wardrik.Statement`, `Wardrik.Tokens`, `Wardrik.Token`, the
  `tokens.*` operations and the `authenticate/2` callback.
- `Wardrik.Resource`, `Definition.principal/1` and the channel installation's
  `approvers` are gone. A notification names its `workspace`.
- `Wardrik.Scope.new/2` takes the server, then `:wardrik`, `:principal`, `:actor` and `:context`.
- Agent IDs are opaque: 1 to 255 characters, no control characters. `Wardrik.AgentID` is gone,
  and `agents.list` and `agent.read` no longer answer a `name`. `{agent}` in a route is one
  URL-encoded segment.
- A conversation is a field, not part of the agent ID. Operations on one take an optional
  `conversation`, and their routes sit under `/v1/agents/{agent}/conversations/{conversation}`.
  `WardrikProtocol.operation/1` gives that route as `:conversation`.
- Events carry `agent` and `conversation` attributes. A cursor encodes a list of
  `[agent, conversation, sequence]`.
- `agents.list`, `agents.forget`, `agents.cancel`, `interrupts.list`, `events.list`,
  `events.head` and `deployment.reload` take `agents`, a list of agent IDs, each with all its
  conversations.
- An operation with two or more path parameters takes one keyword list, including
  `conversation:`: `Wardrik.Agent.approve(scope, agent: "agt_1", interrupt: "call_1",
  conversation: "C1")`. That's `Wardrik.Agent`'s `approve/2`, `deny/2`, `kill/2`,
  `authorization/2`, `trigger_set/2` and `trigger_remove/2`, `Wardrik.Hook.deliver/2`,
  `deliver_with_secret/2` and `Wardrik.Channel.deliver/2`.
- An operation with one path parameter takes `conversation:` in its options:
  `Wardrik.Agent.ask(scope, "agt_1", "Hi", conversation: "C1")`.
- An operation's input takes only its own fields. Any other key raises `ArgumentError`.
- An operation with no fields of its own takes no input: `Wardrik.Agent.read(scope, "agt_1")`.
- `Wardrik.Interrupt`'s `agent_id` is `agent`. `Wardrik.Notice`, `Wardrik.Interrupt` and
  `Wardrik.Server.Follow` carry `conversation`.

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
