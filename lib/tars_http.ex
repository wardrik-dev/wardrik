defmodule TarsHTTP do
  @moduledoc """
  Tars's agents over HTTP: a versioned JSON API, and each agent's event log
  as server-sent events a client resumes after any disconnect.

  A daemon serves it on `127.0.0.1:4747` (see `TarsHTTP.Listener`), and
  `config.yaml` moves it:

      http:
        port: 4747
        ip: 0.0.0.0     # every interface; loopback unless set

  ## Tokens

  Every request presents a token, as `Authorization: Bearer tars_…`. A token
  carries a `Tars.Grant`: the agents under its scope, a key prefix that ends
  at a segment, and the actions it may take on them, every action unless it
  was made with fewer. An agent outside the scope is answered as one that
  does not exist, `404`, and an action the token was not granted is refused
  with `403`. A revoked token is refused, and the streams and worker sockets
  open on it are closed, at once on every node the revocation reaches and
  within 15 seconds on one it does not. See `TarsHTTP.Token`; from a shell:

      tars token create ci --scope acme/
      tars token create watcher --scope acme/ops/ --can read
      tars token create one --scope acme/jon/triage
      tars token create laptop --all
      tars token list
      tars token revoke 3f9a61c0d4e2

  | Action | Routes |
  | --- | --- |
  | `read` | listing agents, snapshots, definitions and events |
  | `message` | messages and cancelling |
  | `decide` | interrupts, and their authorization links |
  | `define` | putting and deleting agents and schedules |
  | `serve` | `/v1/workers` |

  ## Keys in paths

  An agent's key is always three segments, `org/user/name`, with `_` for an
  org or user it has none of. Each segment is one path segment under
  `/v1/agents/`, in the same order:

  | Key | Path |
  | --- | --- |
  | `_/_/researcher` | `/v1/agents/_/_/researcher` |
  | `acme/_/triage` | `/v1/agents/acme/_/triage` |
  | `acme/jon/triage` | `/v1/agents/acme/jon/triage` |

  A segment holds no `/`, so a client percent-encodes each segment on its
  own and joins them with `/`. A path segment that decodes to a `/`, as
  `%2F` does, is refused with `400`. The `id` the API answers an agent with is
  its key.

  ## Routes

  | Route | Answers |
  | --- | --- |
  | `GET /v1/agents` | the agents the token reaches |
  | `GET /v1/agents/{org}/{user}/{name}` | the agent's snapshot, with `sequence`, the last event its log has written |
  | `PUT /v1/agents/{org}/{user}/{name}` | starts the agent a definition describes, `201`, or brings the one running to it, `200`; answers its snapshot |
  | `GET /v1/agents/{org}/{user}/{name}/definition` | the definition last put, as it was sent, where the server keeps definitions |
  | `DELETE /v1/agents/{org}/{user}/{name}` | stops the running agent and deletes everything it had, its schedules included, `204` |
  | `GET /v1/agents/{org}/{user}/{name}/events` | its log as server-sent events, with `Accept: text/event-stream`; otherwise a page of it as JSON |
  | `POST /v1/agents/{org}/{user}/{name}/messages` | queues a message for the agent to answer, `202` |
  | `POST /v1/agents/{org}/{user}/{name}/interrupts/{id}` | approves or rejects a call the agent is waiting on |
  | `GET /v1/agents/{org}/{user}/{name}/interrupts/{id}/authorization` | where a person authorizes a call waiting with reason `authorization`, which no event carries |
  | `POST /v1/agents/{org}/{user}/{name}/cancel` | stops what the agent is doing, and drops what is queued, `202` |
  | `PUT /v1/agents/{org}/{user}/{name}/schedules/{schedule}` | asks the agent a prompt on a clock, `201`, or changes the schedule, `200` |
  | `DELETE /v1/agents/{org}/{user}/{name}/schedules/{schedule}` | stops the schedule and deletes it, `204` |
  | `GET /v1/workers` | a WebSocket a tool worker holds open, to offer tools and answer calls to them |

  `TarsHTTP.Resource` shows what each answers. Each resource's JSON Schema is
  in `priv/protocol/v1`, beside the events': `agent.json` for an agent listed,
  `agent_snapshot.json`, `agent_definition.json`, `schedule.json`,
  `schedule_definition.json`, `authorization.json` and `error.json`. `sdks/typescript` generates
  its types from them.

  ### Agents

      PUT /v1/agents/acme/ops/triage
      {"description": "Watches the incident queue.",
       "instructions": "You watch the incident queue.",
       "model": "anthropic:claude-sonnet-5",
       "tools": ["web_search"]}

  `priv/protocol/v1/agent_definition.json` is the definition's schema. The
  host reads it, with the `TarsHTTP.Definition` the listener is given, and
  decides whether definitions are kept and who owns a key: a key it refuses
  answers `409`. A daemon reads a definition as an agent file (see
  `TarsDaemon.AgentFile`), keeps none, so `GET …/definition` answers `501`,
  and refuses the keys its agent files declare. An agent brought to a new
  definition keeps its conversation and its schedules. A route whose callback
  the module lacks, or every one where the listener has no module, answers
  `501`.

  ### Events

  The stream starts after `Last-Event-ID`, or after `?starting_after=`, and
  without either after the last event written when it connects. A page takes
  `?starting_after=`, `0` by default, and `?limit=`, up to 500. Where events
  after the sequence have been dropped, either answers `410` with the oldest
  one still held; read the snapshot and follow from its `sequence`. See
  `TarsHTTP.EventStream`.

  ### Messages

      POST /v1/agents/acme/ops/triage/messages
      {"id": "msg_01", "parts": [{"type": "text", "content": "What's on fire?"}]}

  `content` in place of `parts` is the text alone. `id` is optional, and a
  message sent again under the same id is taken once. The answer names it:
  `{"message": {"id": "msg_01"}}`.

  ### Interrupts

      POST /v1/agents/acme/ops/triage/interrupts/toolu_01
      {"decision": "reject", "reason": "Not this quarter."}

  `decision` is `approve` or `reject`. The decision is recorded as made by
  the token, and answers `409` when the agent is not waiting on that call,
  and `503` when the agent could not record it.

  ### Schedules

      PUT /v1/agents/acme/ops/triage/schedules/sweep
      {"every": "*/30 * * * *", "prompt": "Check the incident queue."}

  `every` is a cron expression read in UTC, or a duration of at least a
  minute, as `"30m"`. `overlap` is `skip`, the default, or `queue`; `missed`
  is `run_once`, the default, or `skip`; `jitter` is up to so many seconds
  added to each run. See `Tars.Schedule`. The agent has to be running.

  ### Tool workers

  A tool worker is an MCP server that dials in: it opens a WebSocket to
  `/v1/workers` with a token, Tars lists its tools and calls them over it, and
  it answers each call from its own process. See `TarsHTTP.Worker` for the
  messages. An agent whose tools include `workers/*` is offered the tools of
  every worker whose token reaches its key, as `workers__<name>`, and a call
  carries its idempotency key as `_meta.idempotencyKey`. See
  `TarsHTTP.Workers`.

  ## Every response

  Carries a `Request-Id` header, the caller's own where it sent one, and is
  logged under it. An error is `{"error": {"type": …, "message": …}}`.
  """
end
