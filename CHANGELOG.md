# Changelog

## 0.1.0-rc.2

### Breaking

- `start_agent/2` takes an optional `:conversation`. An agent is keyed by
  `{agent_id, conversation}`, with `nil` for the agent's own history. `list/1` and
  `placements/1` return that key. `whereis/2`, `delete/2` and `move/3` take it, or the agent's ID
  alone for its own history. Event metadata and
  `WardrikCore.Context` carry `conversation`.
- `WardrikCore.Credentials` and `WardrikCore.Keys` callbacks take one request struct, then their
  options: `resolve/2` and `refused/2` a `WardrikCore.Credentials.Request`, and `fetch/2` a
  `WardrikCore.Keys.Request`.
- `WardrikCore.evaluate/2` takes the context, then named `:model`, `:state` and `:questions`.
- `WardrikCore.move/3` takes the node as `to:`, so it can't swap with the agent's id.
- `WardrikCore.Retry.run/3` takes `:transient` and `:announce` by name.

## 0.1.0-rc.1 (2026-10-30)

- Durable agents that run a model and its tools in a loop, kept in any `DurableServer` backend.
  They pick up where they left off after a crash. `WardrikCore.Backends.MemoryStore` keeps them in
  memory for tests.
- Capabilities that hand an agent its tools, and middleware that wraps every turn, model call and
  tool call. Middleware can answer a step, or park it until a person resumes it.
- Tool annotations, like `read_only` and `idempotent`. A call lost in a crash is repeated only if
  its tool is idempotent, and parks as `:in_doubt` otherwise.
- Principals, as in IAM. The turn that answers a message acts on behalf of whoever sent it, and
  each step's span says so as `enduser.id`.
- `WardrikCore.Credentials` and `WardrikCore.Keys`, which give tools and model calls the
  credentials and keys of whoever the agent works for. A credential not yet granted parks the call
  on a `WardrikCore.Authorization`.
- `WardrikCore.subagent/3`, which runs a subagent on its parent's model, middleware and tools.
- `WardrikCore.Event`, which sends each event to `:telemetry` and to the agent's
  `WardrikCore.Events` sink. Text streams as `[:wardrik_core, :message, :delta]`.
- Every turn a trace and every step a span, with what each tool reports it cost.
  `WardrikCore.evaluate/4` asks an evaluation model questions about a step.
