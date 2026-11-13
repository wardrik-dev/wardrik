# Changelog

## Unreleased

- An agent, listed or read, has `description` and `model`.
- `events.list` and `agent.events` take `order` and `before`.
- A trigger's `at` runs it once. `agent.trigger_set` returns `next_at`.
- An agent's `status` can be `unreadable`, with `problem` saying why its saved state can't be
  read. `agent.define` answers `reset` when it started such a state over.

## 0.1.0-rc.7 (2026-11-11)

- `digest` in an agent's definition turns off or on the digest it writes of each conversation
  before it sleeps. On by default.
- `agent.files`, `agent.file`, `agent.file_put` and `agent.file_delete` list, read, write and
  delete the files in an agent's workspace. Writes and deletes are recorded as
  `wardrik.file.written` and `wardrik.file.removed`. See `Wardrik.AgentFile`.
- An operation's input describes an agent or conversation ID by what it is. The note on URL
  encoding stays with the HTTP parameter.

## 0.1.0-rc.6 (2026-11-11)

- `deployment.runtime` returns resource use for each node: memory by type, memory the OS
  reports, processes grouped by the module that runs them, processes, ports, atoms and ETS
  tables against their limits, scheduler use, run queue, reductions, garbage collection, I/O,
  versions and, with os_mon, CPU load, memory and disks. It also returns the running agents that
  use the most memory.
- `deployment.nodes` counts the agents on the nodes that are `running`, `idle` and `parked`.
- `agent.runtime` returns a running agent's memory, mailbox size, process count and reductions.
- `agent.resolved` returns what the app gives an agent: who it works for, its policies, MCP
  servers and their tools, notify targets, channels and workspaces.

## 0.1.0-rc.5 (2026-11-06)

- `interrupt.arguments` holds the arguments of the call a person decides on. `name` names that call's tool, which for a coding agent's request differs from the call that parked.

## 0.1.0-rc.4 (2026-11-04)

- `trigger_definition.overlap` takes `settle`, the default for clock and feed triggers. A trigger
  that fires while the agent waits on an unanswered interrupt cancels that turn, then sends its
  prompt.
- `agent.cancelled` has `trigger`, set when a trigger cancelled the turn.
- `agent_definition.model_options`: `temperature`, `top_p`, `max_tokens`, `reasoning_effort`, and
  the model call's timeouts in seconds. No other keys.
- `agent_definition.retries` documents `Retry-After`.

## 0.1.0-rc.3 (2026-11-03)

- A timeline's run has `subagent` steps: a task handed to a delegate, with what it answered.

- `events.list` and `events.head` read only the agents named: `agents` is required.

- `agents.list` takes `limit` and `after`, and answers `next`, the cursor after the page. Without
  `limit`, it lists every agent, as before.

## 0.1.0-rc.2 (2026-11-02)

- The events `wardrik.provider.added`, `wardrik.provider.removed`,
  `wardrik.notify_target.added` and `wardrik.notify_target.removed`.
- Each generated operation function's doc shows a call.
- An interrupt given as `interrupt:` names its own `agent` and `conversation`:
  `Wardrik.Agent.approve(scope, interrupt: interrupt)`.
- `openapi.json` describes what `hook.deliver`, `hook.deliver_with_secret` and
  `channel.deliver` take over HTTP: the request as the service sent it, in any content type.
  `x-wardrik-input` and `x-wardrik-output` give what the operation itself takes and answers.
- `agent.clear` is summarized as clearing a history. The agent and its other conversations stay.

### Breaking

- Behaviour callbacks take a request struct, then options. `Wardrik.Server`'s `run/1` and
  `stream/1` take a `Wardrik.Server.Request`, and `follow/2` a `Wardrik.Server.Follow`.
  `c:Wardrik.Channel.notify/2` takes a `Wardrik.Channel.Notification`.
  `Wardrik.Channel.Installations` callbacks take a `Wardrik.Channel.Installations.Request`.
- Secrets, ceilings, MCP servers and connections are no longer protocol operations.
  `Wardrik.Secrets`, `Wardrik.Ceilings`, `Wardrik.MCPServers`, `Wardrik.Connections` and their
  types and schemas are gone.
- The `wardrik.ceiling.reached` event and its schema are gone. Ceilings belong to the app that
  sets them.
- `agent_definition` no longer speaks of orgs, owners or `config.yaml`. Its example shares
  `agt_runbooks`.
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
- `Wardrik.Agent.decide/2` takes one keyword list too, as `approve/2` and `deny/2` do:
  `decide(scope, agent: "agt_1", decisions: %{"call_1" => :approve}, conversation: "C1")`.
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
