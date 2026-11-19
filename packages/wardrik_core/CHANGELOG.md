# Changelog

## 0.1.0-rc.14 (2026-11-19)

- A tool that answers a list that isn't content parts, as a REST endpoint returning an array, is
  shown it as JSON. It crashed the turn before.

## 0.1.0-rc.13 (2026-11-17)

- `Wardrik.Credentials.Endpoint` is a credential that also says where to connect: a `url` and
  `headers` beside the token. Return it from `resolve/2` when each person or agent reaches a
  service at an address of its own.

## 0.1.0-rc.12 (2026-11-16)

- `Wardrik.Credentials.Request` carries the `agent` whose tool asks, and the tool `call`, or
  `nil` outside one.
- **Upgrading:** the `Wardrik.Credentials` callback `refused/2` is `report_refusal/2`, and so is
  the function. `WardrikCore.parked/1` is `get_parked/1`, `WardrikCore.saved_key/2` is
  `build_state_key/2`, and in `Wardrik.Context`, `reported` and `unreported` are `add_reported`
  and `drop_reported`.

## 0.1.0-rc.11 (2026-11-16)

- Several Wardrik instances can run on one node, each with its own store. `:prefix` sets where an
  instance keeps its agents; `"wardrik/"` unless set. Stored keys are unchanged.
- Heartbeats are polled with every backend. An EKV store no longer subscribes to them.

## 0.1.0-rc.10 (2026-11-15)

- `WardrikCore.evaluate/2` runs as the step `{:evaluate, model}`, whose stop event carries its
  answers and what it used.
- `Wardrik.Context.reported/2` adds measurements an event of their own already reports. A step's
  stop event leaves them out; budgets and spending still count them.

## 0.1.0-rc.9 (2026-11-14)

- `WardrikCore.evaluate/2` passes `ReqLLM.evaluate/4` only the options it takes. Before, every
  call failed on `stream_idle_timeout`, so policy judges asked a person each time.

## 0.1.0-rc.8 (2026-11-14)

- The modules tools, middleware and extensions are written with are named under `Wardrik`:
  `Wardrik.Tool`, `Wardrik.ToolCall`, `Wardrik.Capability`, `Wardrik.Context`, `Wardrik.Resume`,
  `Wardrik.Middleware`, `Wardrik.Principal`, `Wardrik.Credentials`, `Wardrik.Credentials.Request`,
  `Wardrik.Keys`, `Wardrik.Keys.Request` and `Wardrik.Format`, each in place of its
  `WardrikCore` name. `WardrikCore.Authorization` is `Wardrik.Credentials.Authorization`.
- `:endpoints` names models called at their own `base_url`, such as a local OpenAI-compatible
  server. An agent's `:model` may name one. Its calls take only the key its `key` names, never
  its provider's, and are priced as its model.
- An agent keeps its state as JSON, and keeps how it's configured nowhere. `start_agent/2` and
  `configure/2` give a saved agent its settings again as it loads; `:configure`, a
  `WardrikCore.Configure`, gives them to one that loads by itself, as after a crash.
- A park reason or private value a middleware or capability keeps is a `Wardrik.Format`
  with a `type/0`, listed by its `formats/0`. Parking on anything else raises `ArgumentError`.
- A saved state its formats can't read is kept as it was. `start_agent/2` and `configure/2`
  return `{:error, {:unreadable, reason}}`.

## 0.1.0-rc.7 (2026-11-13)

- A tool's JSON Schema is given to the model without its `pattern`s, which some providers refuse,
  such as `\P{Cc}`. Calls are still checked against the whole schema.
- A message's `:sent_at` metadata, now by default, is shown to the model after its text, as
  `(Sent Thursday 2026-11-12 23:40 UTC.)`, so the model knows the date. The history keeps the
  message as asked.
- `WardrikCore.saved_key/2` returns the key an agent's state is saved under in the backend.

## 0.1.0-rc.6 (2026-11-11)

- `WardrikCore.context/1` returns the context the agent's next turn starts from, to run steps
  of your own through its middleware, outside its conversation.

## 0.1.0-rc.5 (2026-11-11)

- `WardrikCore.running/1` returns the process of each running agent, by key, across the cluster.

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
