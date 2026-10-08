---
title: "HTTP API"
description: "Wardrik's agents over HTTP: a versioned JSON API, and each agent's event log as server-sent events a client resumes after any disconnect."
editUrl: false
sidebar:
  order: 5
---

<!-- Written by mix wardrik.docs from WardrikHTTP and packages/wardrik_protocol/priv/v1. Edit it there, not here. -->

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
within 15 seconds on one it does not.

A token that can `define` carries a ceiling: the hooks every agent it
defines is held to, ahead of the definition's own `policy`, so a definition
can narrow what its ceiling allows and never widen it. It is made with one,
a policy of `policies/`, or with none said outright. An agent keeps the
ceiling it was defined under until it is defined again; see `Wardrik.Grant`.

See `WardrikHTTP.Token`; from a shell:

    wardrik token create ci --scope acme/ --policy careful
    wardrik token create watcher --scope acme/@ops/ --can read
    wardrik token create one --scope acme/@jon/triage --policy careful
    wardrik token create laptop --all --unlimited
    wardrik token list
    wardrik token revoke 3f9a61c0d4e2

| Action | Routes |
| --- | --- |
| `read` | listing agents, snapshots, definitions and events |
| `message` | messages, cancelling, and clearing the conversation |
| `decide` | interrupts, and their authorization links |
| `define` | putting and deleting agents and schedules |
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
| `DELETE /v1/agents/{key}` | stops the running agent and deletes everything it had, its schedules included, `204` |
| `GET /v1/agents/{key}/events` | its log as server-sent events, with `Accept: text/event-stream`; otherwise a page of it as JSON |
| `POST /v1/agents/{key}/messages` | queues a message for the agent to answer, `202` |
| `POST /v1/agents/{key}/interrupts/{id}` | approves or rejects a call the agent is waiting on |
| `GET /v1/agents/{key}/interrupts/{id}/authorization` | where a person authorizes a call waiting with reason `authorization`, which no event carries |
| `POST /v1/agents/{key}/cancel` | stops what the agent is doing, and drops what is queued, `202` |
| `DELETE /v1/agents/{key}/conversation` | empties the agent's conversation, and with it the labels of what it held, `204`; `409` while it runs a turn or waits on a person |
| `PUT /v1/agents/{key}/schedules/{schedule}` | asks the agent a prompt on a clock, `201`, or changes the schedule, `200`; `409` where something else, such as an agent file, declares the agent |
| `DELETE /v1/agents/{key}/schedules/{schedule}` | stops the schedule and deletes it, `204`; `409` as for `PUT` |
| `GET /v1/workers` | a WebSocket a tool worker holds open, to offer tools and answer calls to them |

`WardrikHTTP.Resource` shows what each answers. Each resource's JSON Schema is
in `wardrik_protocol`, beside the events': `agent.json` for an agent listed,
`agent_snapshot.json`, `agent_definition.json`, `schedule.json`,
`schedule_definition.json`, `authorization.json` and `error.json`. `sdks/typescript` generates
its types from them.

### Agents

    PUT /v1/agents/acme/triage
    {"description": "Watches the incident queue.",
     "instructions": "You watch the incident queue.",
     "model": "anthropic:claude-sonnet-5",
     "tools": ["web_search"]}

`wardrik_protocol`'s `agent_definition.json` is the definition's schema. The
host reads it, with the `WardrikHTTP.Definition` the listener is given, and
decides whether definitions are kept and who owns a key: a key it refuses
answers `409`. A daemon reads a definition as an agent file (see
`WardrikDaemon.AgentFile`), keeps it, so `GET …/definition` answers it, and
refuses the keys its agent files declare. An agent brought to a new
definition keeps its conversation and its schedules. A route whose callback
the module lacks, or every one where the listener has no module, answers
`501`.

### Events

The stream starts after `Last-Event-ID`, or after `?starting_after=`, and
without either after the last event written when it connects. A page takes
`?starting_after=`, `0` by default, and `?limit=`, up to 500. Where events
after the sequence have been dropped, either answers `410` with the oldest
one still held; read the snapshot and follow from its `sequence`. See
`WardrikHTTP.EventStream`.

### Messages

    POST /v1/agents/acme/triage/messages
    {"id": "msg_01", "parts": [{"type": "text", "content": "What's on fire?"}]}

`content` in place of `parts` is the text alone. `id` is optional, and a
message sent again under the same id is taken once. The answer names it:
`{"message": {"id": "msg_01"}}`.

### Interrupts

    POST /v1/agents/acme/triage/interrupts/toolu_01
    {"decision": "reject", "reason": "Not this quarter."}

`decision` is `approve` or `reject`. The decision is recorded as made by
the token, and answers `409` when the agent is not waiting on that call,
and `503` when the agent could not record it.

### Schedules

    PUT /v1/agents/acme/triage/schedules/sweep
    {"every": "*/30 * * * *", "prompt": "Check the incident queue."}

`every` is a cron expression read in UTC, or a duration of at least a
minute, as `"30m"`. `overlap` is `skip`, the default, or `queue`; `missed`
is `run_once`, the default, or `skip`; `jitter` is up to so many seconds
added to each run. See `Wardrik.Schedule`. The agent has to be running.

### Tool workers

A tool worker is an MCP server that dials in: it opens a WebSocket to
`/v1/workers` with a token, Wardrik lists its tools and calls them over it, and
it answers each call from its own process. See `WardrikHTTP.Worker` for the
messages. An agent whose tools include `workers/*` is offered the tools of
every worker whose token reaches its key, as `workers__<name>`, and a call
carries the agent it is for as `_meta.agent`, its run as `_meta.run`, and
its idempotency key as `_meta.idempotencyKey`. See `WardrikHTTP.Workers`.

## Every response

Carries a `Request-Id` header, the caller's own where it sent one, and is
logged under it. An error is `{"error": {"type": …, "message": …}}`.


## Resources

The bodies the routes take and answer with.

### `agent`

One entry of GET /v1/agents.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | yes | The agent's key, org/name, or org/@user/name for one that works for a user. |
| `name` | string | yes |  |
| `status` | string | yes | One of `idle`, `running`, `parked`. |
| `pending` | integer | yes | Messages waiting for the next run. |
| `node` | string | yes | The node the agent runs on. |
| `outcome` | string |  | How the last run ended. Absent before the first. One of `ok`, `failed`, `interrupted`. |

### `agent_definition`

The body of PUT /v1/agents/{key}, and of GET /v1/agents/{key}/definition, which answers an agent file's definition too. An agent file's frontmatter takes the same keys, with its body as instructions, and name, org, user, schedule and notify besides.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `description` | string |  | What the agent is for, in words a person reads. |
| `instructions` | string |  | The system prompt. |
| `model` | string |  | The model, as provider:model. |
| `tools` | array of string |  | What the agent may call: a tool the server ships, by name; files for the file tools over the agent's own tree and the trees it shares; server/* for every tool of an MCP server; workers/* for every tool the connected tool workers offer it; or * for all of them. |
| `workspace` | object |  | The trees the agent shares with other agents. Only trees the token's scope covers, and tools names files to reach them. |
| `workspace.shared` | object |  | The trees shared with the agent, by the name each is seen under at shared/<name>/: a tree, or a tree and a mode, write unless it says read. |
| `context` | array of string or object |  | The files read into each turn, at most 20, in the agent's tree or one it shares, up to 16 KB of them unless max_bytes says. tools names files to read them with. |
| `policy` | string or object |  |  |
| `timeout` | integer |  | How many seconds a turn may take. |
| `max_iterations` | integer or `"infinity"` |  | How many rounds of tool calls a turn may make. |
| `compaction` | `false` or object |  | When the agent summarises its older history, as shares of the model's window; false never does. |

### `agent_snapshot`

The body of GET /v1/agents/{key}, and of a PUT there. sequence is the last event the agent's log has written: read and follow the log from there.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's key, org/name, or org/@user/name for one that works for a user. |
| `agent.name` | string | yes |  |
| `conversation` | object | yes |  |
| `conversation.id` | string | yes | The key and generation; it changes when the agent is forgotten and started again. |
| `status` | string | yes | One of `idle`, `running`, `parked`. |
| `pending` | integer | yes |  |
| `request` | object | yes |  |
| `request.model` | string | yes |  |
| `provider` | object |  |  |
| `provider.name` | string | yes |  |
| `run` | [run](/reference/events/#run) or null | yes | The run going on, or null between runs. |
| `interrupts` | array of [interrupt](/reference/events/#interrupt) | yes |  |
| `messages` | array of [message](/reference/events/#message) | yes |  |
| `outcome` | string or null | yes | How the last run ended, or null before the first. |
| `sequence` | integer | yes |  |

### `authorization`

Where a person authorizes the call an interrupt with reason authorization waits on: what GET /v1/agents/{key}/interrupts/{id}/authorization answers, to a token that may decide the agent's calls. The link is in no event.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `url` | string | yes | The page to open. |
| `code` | string |  | The code to enter at the page, where one is needed. |

### `error`

What every answer of 400 and above holds. A 410 adds oldest, the first sequence the log still holds.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `error` | object | yes |  |
| `error.type` | string | yes | One of `invalid_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `gap`, `upgrade_required`, `not_supported`, `unavailable`, `internal`. |
| `error.message` | string | yes |  |
| `error.oldest` | integer |  |  |

### `schedule`

A schedule as it was put, the schedule field of what PUT /v1/agents/{key}/schedules/{schedule} answers.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes |  |
| `every` | string | yes | A cron expression, or a duration such as 30m. |
| `prompt` | string | yes | What the agent is asked each time. |
| `overlap` | string | yes | What a firing does while a run is still going: skip it, or queue its prompt. One of `skip`, `queue`. |
| `missed` | string | yes | What a schedule does about the firings it missed while down. One of `run_once`, `skip`. |
| `jitter` | integer | yes | Up to this many seconds of delay, chosen at random each time. |

### `schedule_definition`

The body of PUT /v1/agents/{key}/schedules/{schedule}. overlap is skip, missed is run_once and jitter is 0 where they are left out.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `every` | string | yes | A cron expression, or a duration such as 30m. |
| `prompt` | string | yes | What the agent is asked each time. |
| `overlap` | string |  | What a firing does while a run is still going: skip it, or queue its prompt. One of `skip`, `queue`. |
| `missed` | string |  | What a schedule does about the firings it missed while down. One of `run_once`, `skip`. |
| `jitter` | integer |  | Up to this many seconds of delay, chosen at random each time. |
