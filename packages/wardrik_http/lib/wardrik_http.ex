defmodule WardrikHTTP do
  @moduledoc """
  Wardrik's agents over HTTP: a versioned JSON API, and each agent's event log
  as server-sent events a client resumes after any disconnect.

  A daemon serves it on `127.0.0.1:4747` (see `WardrikHTTP.Listener`), and
  `config.yaml` moves it:

      http:
        port: 4747
        ip: 0.0.0.0     # every interface; loopback unless set

  ## Tokens

  Every request presents a token, as `Authorization: Bearer wardrik_…`. A token
  carries a `Wardrik.Grant`: the agents under its scope, a key prefix that ends
  at a segment, and the actions it may take on them, every action unless it
  was made with fewer. An agent outside the scope is answered as one that
  does not exist, `404`, and an action the token was not granted is refused
  with `403`. A revoked token is refused, and the streams and worker sockets
  open on it are closed, at once on every node the revocation reaches and
  within 15 seconds on one it does not. A token acts for the person it was
  issued to, `--for` them, or for itself, and a decision made with it is
  recorded as theirs.

  A token is the credential the API knows unless its listener is given
  another `WardrikHTTP.Authenticator`, such as a sign-in, which answers the
  caller's grant and who they are the same way.

  A token that can `define` carries a ceiling: the hooks every agent it
  defines is held to, ahead of the definition's own `policy`, so a definition
  can narrow what its ceiling allows and never widen it. It is made with one,
  a policy of `policies/`, or with none said outright. An agent keeps the
  ceiling it was defined under until it is defined again; see `Wardrik.Grant`.

  See `WardrikHTTP.Token`; from a shell:

      wardrik token create ci --scope acme/ --policy careful
      wardrik token create watcher --scope acme/@ops/ --can read
      wardrik token create one --scope acme/@jon/triage --policy careful
      wardrik token create laptop --all --unlimited --for jon
      wardrik token list
      wardrik token revoke 3f9a61c0d4e2

  | Action | Routes |
  | --- | --- |
  | `read` | listing agents, snapshots, definitions, events and connections |
  | `message` | messages, cancelling, and clearing the conversation |
  | `decide` | interrupts, and their authorization links |
  | `define` | putting and deleting agents and schedules, and connecting accounts |
  | `serve` | `/v1/workers` |

  ## Keys in paths

  An agent's key is its path under `/v1/agents/`, as `Wardrik.Fleet` writes
  it: `org/name` for an org's own agent, and `org/@user/name` for one that
  works for a user.

  | Key | Path |
  | --- | --- |
  | `acme/triage` | `/v1/agents/acme/triage` |
  | `acme/@jon/triage` | `/v1/agents/acme/@jon/triage` |

  A segment holds no `/`, so a client percent-encodes each segment on its
  own and joins them with `/`; `@` may be sent as it is or as `%40`. A path
  segment that decodes to a `/`, as `%2F` does, is refused with `400`, and so
  is a key `Wardrik.Fleet` would not have written. The `id` the API answers an
  agent with is its key.

  ## Routes

  | Route | Answers |
  | --- | --- |
  | `GET /v1/agents` | the agents the token reaches |
  | `GET /v1/agents/{key}` | the agent's snapshot, with `sequence`, the last event its log has written |
  | `PUT /v1/agents/{key}` | starts the agent a definition describes, `201`, or brings the one running to it, `200`; answers its snapshot |
  | `GET /v1/agents/{key}/definition` | the definition last put, as it was sent, where the server keeps definitions |
  | `DELETE /v1/agents/{key}` | stops the running agent and deletes everything it had, its definition and schedules included, `204` |
  | `GET /v1/agents/{key}/events` | its log as server-sent events, with `Accept: text/event-stream`; otherwise a page of it as JSON |
  | `POST /v1/agents/{key}/messages` | queues a message for the agent to answer, `202` |
  | `POST /v1/agents/{key}/interrupts/{id}` | approves or rejects a call the agent is waiting on |
  | `GET /v1/agents/{key}/interrupts/{id}/authorization` | where a person authorizes a call waiting with reason `authorization`, which no event carries |
  | `POST /v1/agents/{key}/cancel` | stops what the agent is doing, and drops what is queued, `202` |
  | `DELETE /v1/agents/{key}/conversation` | empties the agent's conversation, and with it the labels of what it held, `204`; `409` while it runs a turn or waits on a person |
  | `PUT /v1/agents/{key}/schedules/{schedule}` | asks the agent a prompt on a clock, `201`, or changes the schedule, `200`, in the definition kept; `404` where none is, `409` where something else, such as an agent file, declares the agent |
  | `DELETE /v1/agents/{key}/schedules/{schedule}` | stops the schedule and deletes it, `204`; `404` where the agent has none, `409` as for `PUT` |
  | `GET /v1/exports/{name}` | a page of every log the caller may read, after the export's cursor |
  | `POST /v1/exports/{name}` | moves the export's cursor to a page's `next`, `204` |
  | `DELETE /v1/exports/{name}` | deletes the export's cursor, so it reads from the start again, `204` |
  | `GET /v1/connections` | the accounts the caller's org is offered, and whether they, the org or the deployment holds each |
  | `POST /v1/connections/{provider}` | connects an account: where to authorize it, or that it is held already |
  | `DELETE /v1/connections/{provider}` | forgets the account, so the next call that needs it asks again, `204` |
  | `GET /v1/workers` | a WebSocket a tool worker holds open, to offer tools and answer calls to them |

  `Wardrik.Resource` shows what each answers. Each resource's JSON Schema is
  in `wardrik_protocol`, beside the events': `agent.json` for an agent listed,
  `agent_snapshot.json`, `agent_definition.json`, `schedule.json`,
  `schedule_definition.json`, `authorization.json`, `connections.json`,
  `connecting.json`, `export.json` and `error.json`. `sdks/typescript` generates
  its types from them.

  ### Agents

      PUT /v1/agents/acme/triage
      {"description": "Watches the incident queue.",
       "instructions": "You watch the incident queue.",
       "model": "anthropic:claude-sonnet-5",
       "tools": ["web_search"]}

  `wardrik_protocol`'s `agent_definition.json` is the definition's schema. The
  host reads it, with the `Wardrik.Definition` it names as `Wardrik`'s
  `:definitions`, and decides whether definitions are kept and who owns a
  key: a key it refuses answers `409`. A daemon reads a definition as an agent file (see
  `WardrikDaemon.AgentFile`), keeps it, so `GET …/definition` answers it, and
  refuses the keys its agent files declare. An agent brought to a new
  definition keeps its conversation. A route whose callback the module
  lacks, or every one where the host names no module, answers `501`.

  ### Events

  The stream starts after `Last-Event-ID`, or after `?starting_after=`, and
  without either after the last event written when it connects. A page takes
  `?starting_after=`, `0` by default, and `?limit=`, up to 500. Where events
  after the sequence have been dropped, either answers `410` with the oldest
  one still held; read the snapshot and follow from its `sequence`. See
  `WardrikHTTP.EventStream`.

  ### Exports

      GET /v1/exports/siem?limit=500
      POST /v1/exports/siem
      {"next": "eyJhY21lL3RyaWFnZSI6NDF9"}

  An export is a cursor of the caller's own, kept on the server under the
  name it gives, over every log it may read: each agent's it may `read`, a
  removed agent's included, and the audit of what people changed where it
  reaches every agent. A page answers the events after the cursor and leaves
  it there, so reading again answers them again; posting the page's `next`
  moves it past them, once they are safely kept. `gaps` names each log
  trimmed past the cursor, which was read from its oldest event. See
  `Wardrik.Event.Export`.

  ### Messages

      POST /v1/agents/acme/triage/messages
      {"id": "msg_01", "parts": [{"type": "text", "content": "What's on fire?"}]}

  `content` in place of `parts` is the text alone. `id` is optional, and a
  message sent again under the same id is taken once. The answer names it:
  `{"message": {"id": "msg_01"}}`.

  ### Interrupts

      POST /v1/agents/acme/triage/interrupts/toolu_01
      {"decision": "reject", "reason": "Not this quarter."}

  `decision` is `approve` or `reject`. A rejection's `reason` is what the
  model is told in place of the call's answer; an approval's `note`, as in
  `{"decision": "approve", "note": "Only this once."}`, is what it reads
  beside the answer, and never changes the call, which runs as the model
  wrote it. The decision is recorded as made by the caller's principal, and answers `409` when the agent is not waiting on that call,
  and `503` when the agent could not record it.

  ### Schedules

      PUT /v1/agents/acme/triage/schedules/sweep
      {"every": "*/30 * * * *", "prompt": "Check the incident queue."}

  `every` is a cron expression read in UTC, or a duration of at least a
  minute, as `"30m"`. `overlap` is `skip`, the default, or `queue`; `missed`
  is `run_once`, the default, or `skip`; `jitter` is up to so many seconds
  added to each run. A schedule is part of the agent's definition, which the
  host keeps: a definition put again lists every schedule the agent has, and
  an agent with no definition kept answers `404`.

  ### Connections

      GET /v1/connections
      {"connections": [{"provider": "github", "held_by": "person"},
                       {"provider": "linear"}]}

      POST /v1/connections/linear
      {"provider": "linear", "connected": false,
       "authorization": {"url": "https://linear.app/oauth/authorize?…"}}

  A caller's connections are its person's, within the org its token reaches:
  the user its scope names, else the user it was made `--for`. With
  `?owner=org` they are the org's, for a token that may `define` under the
  org. A token for no person asks with `?owner=org`, and one that reaches
  every org asks with a token for one. Connecting asks nobody to approve
  anything and parks nothing: the account is held once the person has
  authorized it at the link, and the audit records it as stored by the
  caller. A value is never answered. The host names what offers
  connections as `Wardrik`'s `:connections`; see `Wardrik.Connections`.

  ### Tool workers

  A tool worker is an MCP server that dials in: it opens a WebSocket to
  `/v1/workers` with a token, Wardrik lists its tools and calls them over it, and
  it answers each call from its own process. See `WardrikHTTP.Worker` for the
  messages. An agent whose tools include `workers/*` is offered the tools of
  every worker whose token reaches its key, as `workers__<name>`, and a call
  carries the agent it is for as `_meta.agent`, its run as `_meta.run`, and
  its idempotency key as `_meta.idempotencyKey`. A worker that answers with
  `_meta.costUsd` says what the call cost in US dollars, which the call's
  `tool_call.completed` event carries and a budget counts. See
  `WardrikHTTP.Workers`.

  ## Every response

  Carries a `Request-Id` header, the caller's own where it sent one, and is
  logged under it. An error is `{"error": {"type": …, "message": …}}`. A
  request that changes something, defining, deleting, scheduling, cancelling
  or clearing, is recorded in `Wardrik.Audit` with the caller's principal.
  """
end
