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

Every request presents a token, as `Authorization: Bearer wardrik_…`, but one
to `/v1/hooks/`, which a trigger checks the signature of instead. A token
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
| `read` | listing agents, snapshots, definitions, events and connections; the deployment's nodes and audit |
| `message` | messages, cancelling, and clearing the conversation |
| `decide` | interrupts, and their authorization links |
| `define` | putting and deleting agents and triggers, connecting accounts, and reloading the deployment |
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
| `GET /v1/agents` | the agents under `?prefix=`, or every one the token reaches; `403` where it may not read them |
| `POST /v1/agents/cancel?prefix=` | stops what every agent under the prefix is doing, where it is taking a turn, `202`; `prefix=` alone is every agent |
| `DELETE /v1/agents?prefix=` | removes every agent under the prefix but those the server keeps, as an agent file declares; answers which went, which stayed and why |
| `GET /v1/interrupts` | the calls agents under `?prefix=`, or every one the token reaches, wait on a person for |
| `GET /v1/agents/{key}` | the agent's snapshot, with `sequence`, the last event its log has written |
| `PUT /v1/agents/{key}` | starts the agent a definition describes, `201`, or brings the one running to it, `200`; answers its snapshot |
| `GET /v1/agents/{key}/definition` | the definition last put, as it was sent, where the server keeps definitions |
| `DELETE /v1/agents/{key}` | stops the agent and deletes everything it had, its definition and triggers included; `409` where something else, such as an agent file, declares it |
| `GET /v1/agents/{key}/events` | its log as server-sent events, with `Accept: text/event-stream`; otherwise a page of it as JSON |
| `POST /v1/agents/{key}/messages` | queues a message for the agent to answer, `202` |
| `POST /v1/agents/{key}/decisions` | approves or rejects calls the agent is waiting on, together |
| `GET /v1/agents/{key}/interrupts/{id}/authorization` | where a person authorizes a call waiting with reason `authorization`, which no event carries |
| `POST /v1/agents/{key}/cancel` | stops what the agent is doing, and drops what is queued, `202`; an agent taking no turn is left as it is |
| `POST /v1/agents/{key}/spawn` | starts the agent: wakes it, starts it on its definition, or has the server define it; with `{"node": ...}`, on that node, to a token over every agent |
| `POST /v1/agents/{key}/stop` | stops the agent, keeping its conversation, so it sleeps until something asks it |
| `POST /v1/agents/{key}/move` | starts the agent again on `{"node": ...}`, with its conversation, to a token over every agent |
| `DELETE /v1/agents/{key}/conversation` | empties the agent's conversation, and with it the labels of what it held, `204`; `409` while it runs a turn or waits on a person |
| `PUT /v1/agents/{key}/triggers/{trigger}` | asks the agent a prompt on a clock, `201`, or changes the trigger, `200`, in the definition kept; `404` where none is, `409` where something else, such as an agent file, declares the agent |
| `DELETE /v1/agents/{key}/triggers/{trigger}` | stops the trigger and deletes it, `204`; `404` where the agent has none, `409` as for `PUT` |
| `POST /v1/hooks/{key}/{trigger}`, or `.../{trigger}/{secret}` | delivers a service's request to a webhook trigger, with no token but the trigger's secret, as `Authorization: Bearer` or at the end of the path: `202`, and whether the agent was asked or had been about the same request; `404` where the agent has no such trigger, or its signature does not match, so a sender learns nothing of the triggers it cannot sign for; and `503` where it cannot be delivered now, so a sender that tries again delivers it later |
| `GET /v1/exports/{name}` | a page of every log the caller may read, after the export's cursor |
| `POST /v1/exports/{name}` | moves the export's cursor to a page's `next`, `204` |
| `DELETE /v1/exports/{name}` | deletes the export's cursor, so it reads from the start again, `204` |
| `GET /v1/connections` | the accounts the caller's org is offered, and whether they, the org or the deployment holds each |
| `POST /v1/connections/{provider}` | connects an account: where to authorize it, or that it is held already |
| `DELETE /v1/connections/{provider}` | forgets the account, so the next call that needs it asks again, `204` |
| `POST /v1/deployment/reload` | has every node whose host reads its definitions again do so, and answers those nodes; `501` where none does |
| `GET /v1/deployment/nodes` | the deployment's nodes, each with how many agents run on it, and how many sleep |
| `GET /v1/deployment/audit` | a page of what people changed across the deployment, after `?starting_after=` |
| `GET /v1/workers` | a WebSocket a tool worker holds open, to offer tools and answer calls to them |

The `/v1/deployment` routes are for a token over every agent alone; any
other is answered `403`. Tokens are made only from a shell on the server,
never over the API.

A route that changes something answers what it would do, and does
nothing, with `?plan=true`: a cancel the agents it would stop, as
`{"cancelling": [...]}`, a removal those it would remove and those it
would keep, as `{"forgetting": [...], "keeping": [{"id": ..., "why": ...}]}`.
Done, a cancel answers `{"cancelled": [...]}`, and a removal
`{"forgotten": [...], "kept": [...], "failed": [...]}`.

`Wardrik.Resource` shows what each answers. Each resource's JSON Schema is
in `wardrik_protocol`, beside the events': `agent.json` for an agent listed,
`agent_snapshot.json`, `agent_definition.json`, `trigger.json`,
`trigger_definition.json`, `authorization.json`, `connections.json`,
`connecting.json`, `export.json`, `nodes.json` and `error.json`. `sdks/typescript` generates
its types from them.

### Agents

    PUT /v1/agents/acme/triage
    {"description": "Watches the incident queue.",
     "instructions": "You watch the incident queue.",
     "model": "anthropic:claude-sonnet-5",
     "tools": ["web_search"]}

`wardrik_protocol`'s `agent_definition.json` is the definition's schema. The
host reads it, with the `Wardrik.Definition` its `Wardrik.Host` names as
`:definitions`, the host `WardrikHTTP.Listener` was started with, and
decides whether definitions are kept and who owns a key: a key it refuses
answers `409`. A daemon reads a definition as an agent file (see
`WardrikDaemon.AgentFile`), keeps it, so `GET …/definition` answers it, and
refuses the keys its agent files declare. An agent brought to a new
definition keeps its conversation. A route the host's module answers
`:unsupported`, as every one where the host names none does, answers
`501`.

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
`{"message": {"id": "msg_01"}}`. The model reads the message as from the
caller's principal.

### Decisions

    POST /v1/agents/acme/triage/decisions
    {"decisions": [{"id": "toolu_01", "decision": "reject", "reason": "Not this quarter."}]}

Each decision names a call the agent waits on, an interrupt's `id`, and
is `approve` or `reject`; `wardrik_protocol`'s `decisions.json` is the
body's schema. A rejection's `reason` is what the model is told in place
of the call's answer; an approval's `note`, as in
`{"id": "toolu_01", "decision": "approve", "note": "Only this once."}`, is
what it reads beside the answer, and never changes the call, which runs as
the model wrote it. The decisions are taken together, and recorded as made
by the caller's principal. The answer lists each call with `approved` or
`rejected`; `409` where the agent is not waiting on one of them, and `503`
where it could not record them.

### Triggers

    PUT /v1/agents/acme/triage/triggers/sweep
    {"every": "*/30 * * * *", "prompt": "Check the incident queue."}

`every` is a cron expression read in UTC, or a duration of at least a
minute, as `"30m"`. `overlap` is `skip`, the default, or `queue`; `missed`
is `run_once`, the default, or `skip`; `jitter` is up to so many seconds
added to each run. A trigger is part of the agent's definition, which the
host keeps: a definition put again lists every trigger the agent has, and
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

### The deployment

    GET /v1/deployment/nodes
    {"nodes": [{"name": "wardrik@box1", "agents": 12}], "asleep": 40}

    GET /v1/deployment/audit?starting_after=120&limit=50
    {"changes": [{"type": "wardrik.agent.defined", "subject": "agents/acme/triage", …}]}

A change in the audit is a CloudEvent, as an agent's events are, whose
`data.actor` is who made it; see `Wardrik.Audit` for every type. A page
asked for before the oldest change kept is a `gap`, as an agent's events
are. A reload has every node whose host reads its definitions again, as a
daemon reads its agent and policy files, do so, and answers
`{"reloaded": [...]}`, the nodes that did.

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
request that changes something, defining, deleting, setting triggers, cancelling
or clearing, is recorded in `Wardrik.Audit` with the caller's principal.


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
| `asleep` | boolean | yes | Whether it has gone to sleep for having had nothing to do; it wakes when something asks it. |
| `node` | string |  | The node the agent runs on. Absent while it sleeps. |
| `outcome` | string |  | How the last run ended. Absent before the first. One of `ok`, `failed`, `interrupted`. |

### `agent_definition`

The body of PUT /v1/agents/{key}, and of GET /v1/agents/{key}/definition, which answers an agent file's definition too. An agent file's frontmatter takes the same keys, with its body as instructions, and name, org and user besides.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `description` | string |  | What the agent is for, in words a person reads. |
| `instructions` | string |  | The system prompt. |
| `model` | string |  | The model, as provider:model. |
| `tools` | array of string |  | What the agent may call: a tool the server ships, by name; files for the file tools over the agent's own tree and the trees it shares; server/* for every tool of an MCP server; workers/* for every tool the connected tool workers offer it; self/* for its operations on itself; agents/* for its operations on the agents of its org; or * for all of them. |
| `workspace` | object |  | The trees the agent shares with other agents. Only trees the token's scope covers, and tools names files to reach them. |
| `workspace.shared` | object |  | The trees shared with the agent, by the name each is seen under at shared/<name>/: a tree, or a tree and a mode, write unless it says read. |
| `context` | array of string or object |  | The files read into each turn, at most 20, in the agent's tree or one it shares, up to 16 KB of them unless max_bytes says. tools names files to read them with. |
| `policy` | string or object |  |  |
| `timeout` | integer |  | How many seconds a turn may take. |
| `idle_timeout` | integer or `"infinity"` |  | How many seconds the agent may have nothing to do before it sleeps, until something asks it. The server's default when absent. |
| `max_iterations` | integer or `"infinity"` |  | How many rounds of tool calls a turn may make. |
| `retries` | array of integer |  | How many seconds a turn waits before asking a model call again that failed for a passing reason, such as a timeout, one for each try: [1, 5] where neither this nor the host's defaults say. [] never asks again. |
| `compaction` | `false` or object |  | When the agent summarises its older history, as shares of the model's window; false never does. |
| `triggers` | array of object |  | The triggers that ask the agent something when they come round, each with a prompt or a prompt_file. A definition put again replaces them all, and PUT and DELETE /v1/agents/{key}/triggers/{trigger} change one. Any other field is the source's that the trigger watches, which one of them names; without one, it asks on every run. A trigger on a clock has every; a webhook has webhook in its place, holding its secret and how a request is verified, and is sent requests at POST /v1/hooks/{key}/{trigger}. |
| `notify` | string or array of string or object |  | Who hears when the agent parks, fails or answers: a target config.yaml's notify names, a list of them, or to and on. A target tells only the agents of the orgs it serves. |
| `channels` | array of string |  | The chat channels, as config.yaml names them, it may be chosen to answer in. |

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
| `labels` | array of string | yes | What the agent's history holds, as labels, such as outside for content nobody on the agent's side wrote. Every turn carries them until the history is cleared. |
| `outcome` | string or null | yes | How the last run ended, or null before the first. |
| `sequence` | integer | yes |  |

### `authorization`

Where a person authorizes the call an interrupt with reason authorization waits on: what GET /v1/agents/{key}/interrupts/{id}/authorization answers, to a token that may decide the agent's calls. The link is in no event.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `url` | string | yes | The page to open. |
| `code` | string |  | The code to enter at the page, where one is needed. |

### `connecting`

What POST /v1/connections/{provider} answers: that the owner holds the account already, or where to authorize it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `provider` | string | yes | The account's name, as the deployment configures it. |
| `connected` | boolean | yes | Whether the owner holds it already. |
| `authorization` | [urn:wardrik:schema:v1:authorization](/reference/events/#urn:wardrik:schema:v1:authorization) |  | Where to authorize it, where it is not held yet. |

### `connections`

The accounts an owner's org is offered, and who holds each: what GET /v1/connections answers. A value is never answered.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `connections` | array of object | yes |  |

### `decisions`

The body of POST /v1/agents/{key}/decisions: what a person decides of the calls an agent waits on, taken together. The answer lists each call's id with approved or rejected.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `decisions` | array of object | yes |  |

### `error`

What every answer of 400 and above holds. A 410 adds oldest, the first sequence the log still holds.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `error` | object | yes |  |
| `error.type` | string | yes | One of `invalid_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `gap`, `upgrade_required`, `not_supported`, `unavailable`, `internal`. |
| `error.message` | string | yes |  |
| `error.oldest` | integer |  |  |

### `export`

What GET /v1/exports/{name} answers: the events after the export's cursor, in every log the caller may read.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `events` | array of [urn:wardrik:schema:v1:cloudevent](/reference/events/#urn:wardrik:schema:v1:cloudevent) | yes | Oldest first within each log; each event's source names its log, and its sequence its place there. |
| `next` | string | yes | What POST /v1/exports/{name} takes, as {"next": …}, to move the cursor past these events. |
| `gaps` | array of object | yes | Each log trimmed past the cursor, which was read from its oldest event. |

### `nodes`

The deployment's nodes, each with how many agents run on it, and how many agents sleep on none: what GET /v1/deployment/nodes answers.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `nodes` | array of object | yes |  |
| `asleep` | integer | yes | How many agents sleep, on no node, until something asks them. |

### `trigger`

A trigger as it was put, the trigger field of what PUT /v1/agents/{key}/triggers/{trigger} answers. A trigger on a clock has every, missed and jitter, and any other field is the source's that it watches, which one of them names; without one, it asks on every run. A webhook has webhook, its secret and how a request is verified, and asks as each request arrives.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes |  |
| `every` | string |  | A cron expression, or a duration such as 30m. |
| `prompt` | string | yes | What the agent is asked each time. |
| `overlap` | string | yes | What a firing does while a run is still going: skip it, or queue its prompt. One of `skip`, `queue`. |
| `missed` | string |  | What a trigger does about the firings it missed while down. One of `run_once`, `skip`. |
| `jitter` | integer |  | Up to this many seconds of delay, chosen at random each time. |

### `trigger_definition`

The body of PUT /v1/agents/{key}/triggers/{trigger}, with a prompt or a prompt_file. A trigger on a clock has every; overlap is skip, missed is run_once and jitter is 0 where they are left out, and any other field is the source's that it watches, which one of them names; without one, it asks on every run. A webhook has webhook in place of every, holding its secret, as ${NAME}, and verify, shared or standard; it is sent requests at POST /v1/hooks/{key}/{trigger}, and its overlap is queue where it says none.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `every` | string |  | A cron expression, or a duration such as 30m. |
| `prompt` | string |  | What the agent is asked each time. |
| `prompt_file` | string |  | In place of prompt, a file in the agent's tree: each time, the agent is asked to read it and do what it says. tools names files to read it with. |
| `overlap` | string |  | What a firing does while a run is still going: skip it, or queue its prompt. One of `skip`, `queue`. |
| `missed` | string |  | What a trigger does about the firings it missed while down. One of `run_once`, `skip`. |
| `jitter` | integer |  | Up to this many seconds of delay, chosen at random each time. |
