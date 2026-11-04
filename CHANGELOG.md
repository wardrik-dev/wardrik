# Changelog

## 0.1.0-rc.4 (2026-11-04)

- A failed model call with `Retry-After` in seconds is retried after that delay, up to
  `max_wait`.

### Breaking

- `:model_options` replaces `:model_timeouts`. It takes any `ReqLLM` option and is merged over the
  five-minute timeouts. `WardrikCore.Context.model_options/2` returns a call's options and key.

## 0.1.0-rc.3 (2026-11-03)

### Changed

- A model call waits up to five minutes for an answer, and as long on a stream gone quiet. Set
  `:model_timeouts` on `start_agent/2` to change them.
- `durable_server` is pinned to 0.1.7: `list/1` reads its backend's listing.

### Fixed

- `list/1` reads only keys from the backend, not every agent's state.

## 0.1.0-rc.2 (2026-11-02)

### Breaking

- `start_agent/2` takes an optional `:conversation`. Agents are keyed by
  `{agent_id, conversation}`; `nil` is the main history.
- `list/1` and `placements/1` return those keys. `whereis/2`, `delete/2` and `move/3` take a key,
  or an agent ID alone for its main history.
- Event metadata and `WardrikCore.Context` carry `conversation`.
- `WardrikCore.Credentials` and `WardrikCore.Keys` callbacks take a request struct, then their
  options: `WardrikCore.Credentials.Request` or `WardrikCore.Keys.Request`.
- `c:WardrikCore.Keys.fetch/2` returns `{:ok, key}` or `{:error, reason}`, as the other callbacks
  do. `{:error, :not_found}` says there's none.
- `WardrikCore.evaluate/2` takes the context, then `:model`, `:state` and `:questions`.
- `WardrikCore.move/3` takes the node as `to:`.
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
  `WardrikCore.evaluate` asks an evaluation model questions about a step.
