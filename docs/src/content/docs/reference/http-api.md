---
title: "HTTP API"
description: "Wardrik's agents over HTTP: a versioned JSON API, and each agent's event log as server-sent events a client resumes after any disconnect."
editUrl: "https://github.com/wardrik-dev/wardrik/edit/main/packages/wardrik_http/guides/http-api.md"
sidebar:
  order: 5
---

<!-- Written by mix wardrik.docs from packages/wardrik_http/guides/http-api.md and packages/wardrik_core/priv/v1. Edit it there, not here. -->

Wardrik's agents over HTTP: a versioned JSON API, and each agent's event log as server-sent events a
client resumes after any disconnect.

The daemon serves it on `127.0.0.1:4747`, and `config.yaml` moves it:

```yaml
http:
  port: 4747
  ip: 0.0.0.0     # every interface; loopback unless set
```

See [Use the HTTP API](/build/http-api/) for a walk through it, and the
TypeScript SDK for a client.

## Tokens

Every request presents a token, as `Authorization: Bearer wardrik_…`, except a webhook's to
`/v1/hooks/`, which its trigger checks instead, and a chat app's to `/v1/channels/`, which its
channel checks. `wardrik token create` makes one from a shell on the server, and `/v1/tokens`
over the API:

```sh
wardrik token create ci --scope acme/ --role reader,messenger,definer --policy careful
wardrik token create watcher --scope acme/@ops/ --role reader
wardrik token create one --scope acme/@jon/triage --role owner --expires 30d
wardrik token create laptop --all --role owner
wardrik token list
wardrik token revoke 3f9a61c0d4e2
```

A token's statements each allow some actions, named for what a route does, such as `agent.ask`,
on the agents under a key prefix that ends at a segment. Anything no statement allows is denied. An
agent no statement reaches is answered as one that doesn't exist, `404`, and an action not allowed
on one it reaches is refused with `403`. A role is a named set of actions:

| Role | Routes |
| --- | --- |
| `reader` | listing agents, snapshots, definitions, events, the tool calls an agent is running, the calls agents wait on, connections and servers |
| `messenger` | messages, cancelling, and clearing the conversation |
| `approver` | decisions, and authorization links |
| `definer` | putting, starting, stopping and deleting agents and triggers, stopping a tool call, connecting accounts, and adding and removing servers |
| `worker` | `/v1/workers` |
| `owner` | every route; with `--all`, the deployment and `/v1/tokens` too |

A token acts for whoever made it, and a change made with it is recorded as theirs. It works for 90
days, or as long as `--expires` or `expires_in` says, and an expired token is refused with `401`. A
revoked token is refused, and the streams and worker sockets open on it are closed, at once on
every node the revocation reaches and within 15 seconds on one it doesn't.

A token's policy names a policy every agent it defines runs under, ahead of the definition's own,
so a definition can narrow what it allows and never widen it: what IAM calls a permissions boundary.
It is read by its name each time such an agent starts. It is made with `--policy`, or `policy` over
the API, and is the maker's own where neither names one.

## Keys in paths

An agent's key is its path under `/v1/agents/`: `org/name` for an org's own agent, and
`org/@user/name` for one that works for a user.

| Key | Path |
| --- | --- |
| `acme/triage` | `/v1/agents/acme/triage` |
| `acme/@jon/triage` | `/v1/agents/acme/@jon/triage` |

A client percent-encodes each segment on its own and joins them with `/`; `@` may be sent as it is
or as `%40`. A segment that decodes to a `/`, as `%2F` does, is refused with `400`. The `id` the API
answers an agent with is its key.

## Routes

| Route | Answers |
| --- | --- |
| `GET /v1/agents` | the agents under `?prefix=`, or every one the token reaches |
| `POST /v1/agents/cancel?prefix=` | stops what every agent under the prefix is doing, `202`; `prefix=` alone is every agent |
| `DELETE /v1/agents?prefix=` | removes every agent under the prefix but those agent files declare; answers which went, which stayed and why |
| `GET /v1/interrupts` | the calls agents under `?prefix=`, or every one the token reaches, wait on a person for |
| `GET /v1/agents/{key}` | the agent's snapshot, with `sequence`, the last event its log has written |
| `PUT /v1/agents/{key}` | starts the agent a definition describes, or brings the one running to it; answers its snapshot |
| `GET /v1/agents/{key}/definition` | the definition last put, as it was sent, with the tools it names that offer nothing yet as `missing` |
| `DELETE /v1/agents/{key}` | stops the agent and deletes everything it had, its definition and triggers included, `204`; `409` where an agent file declares it |
| `GET /v1/agents/{key}/events` | its log as server-sent events, with `Accept: text/event-stream`; otherwise a page of it as JSON |
| `POST /v1/agents/{key}/messages` | queues a message for the agent to answer, `202` |
| `POST /v1/agents/{key}/decisions` | approves or rejects calls the agent is waiting on, together |
| `GET /v1/agents/{key}/interrupts/{id}/authorization` | where a person authorizes a call waiting with reason `authorization` |
| `POST /v1/agents/{key}/cancel` | stops what the agent is doing, and drops what is queued, `202` |
| `GET /v1/agents/{key}/calls` | the tool calls the agent is running, each with how long it has run; `404` while it sleeps |
| `DELETE /v1/agents/{key}/calls/{call}` | stops one tool call the agent is running, `204`: the model is answered with an error, and the turn goes on |
| `POST /v1/agents/{key}/spawn` | starts the agent; with `{"node": ...}`, on that node, to a token over every agent |
| `POST /v1/agents/{key}/stop` | stops the agent, keeping its conversation, so it sleeps until something asks it; answers it, asleep |
| `POST /v1/agents/{key}/move` | starts the agent again on `{"node": ...}`, with its conversation, to a token over every agent |
| `DELETE /v1/agents/{key}/conversation` | empties the agent's conversation, and the labels of what it held, and answers its snapshot; `409` while it runs a turn or waits on a person |
| `PUT /v1/agents/{key}/triggers/{trigger}` | sets or changes a trigger, and answers it; `404` where no definition is kept, `409` where an agent file declares the agent |
| `DELETE /v1/agents/{key}/triggers/{trigger}` | stops the trigger and deletes it, and answers it as it was |
| `POST /v1/hooks/{key}/{trigger}`, or `.../{trigger}/{secret}` | delivers a service's request to a webhook trigger; see [Webhooks](#webhooks) |
| `POST /v1/channels/{channel}/{path}` | delivers what a chat app, such as Slack, sends a channel; see [Channels](#channels) |
| `GET /v1/exports/{name}` | a page of every log the caller may read, after the export's cursor |
| `POST /v1/exports/{name}` | moves the export's cursor to a page's `next`, `204` |
| `DELETE /v1/exports/{name}` | deletes the export's cursor, so it reads from the start again, `204` |
| `GET /v1/connections?prefix=` | the accounts the owner `prefix` names is offered, and whether they, their org or the deployment holds each |
| `POST /v1/connections/{provider}` | connects an account: where to authorize it, or that it is held already |
| `DELETE /v1/connections/{provider}` | forgets the account, so the next call that needs it asks again, and answers it as it was held |
| `GET /v1/servers?prefix=` | the MCP servers the owner `prefix` names added for their agents |
| `POST /v1/servers?prefix=` | adds an MCP server for the owner's agents, `201`: that they can call it now, or where to sign in to it first |
| `DELETE /v1/servers/{name}?prefix=` | removes the server, so the owner's agents can no longer call it, and answers it as it was |
| `POST /v1/deployment/reload` | has every node read its agent and policy files again, and answers those nodes |
| `GET /v1/deployment/nodes` | the deployment's nodes, each with how many agents run on it, and how many sleep |
| `GET /v1/deployment/audit` | a page of what people changed across the deployment, after `?starting_after=` |
| `GET /v1/tokens` | every token, oldest first, never a secret |
| `POST /v1/tokens` | makes a token from its `name`, `scope`, `roles`, `policy` and `expires_in`, `201`, with its `secret`, given this once |
| `DELETE /v1/tokens/{id}` | revokes the token, and answers it as it was |
| `GET /v1/workers` | a WebSocket a tool worker holds open, to offer tools and answer calls to them |

The `/v1/deployment` and `/v1/tokens` routes are for an `owner` token over every agent alone.

A cancel under a prefix answers `{"cancelled": [...]}`, and a removal
`{"forgotten": [...], "kept": [{"id": ..., "why": ...}], "failed": [...]}`.

wardrik_core's `priv/openapi.json` is every route in OpenAPI 3.1: what each takes and
answers, and the function of `Wardrik` it calls. A client generator in any language reads
`priv/openapi.bundled.json`, the same with every schema in it.

[Resources](#resources), below, lists what each route takes and answers. The TypeScript SDK's types
are generated from the same schemas.

### Agents

```http
PUT /v1/agents/acme/triage

{"description": "Watches the incident queue.",
 "instructions": "You watch the incident queue.",
 "model": "anthropic:claude-sonnet-5",
 "tools": ["web_search"]}
```

A definition takes the keys of an [agent file](/reference/agent-files/), with
`instructions` as its system prompt. The daemon keeps it, so `GET …/definition` answers it, and
refuses a key an agent file declares with `409`. An agent brought to a new definition keeps its
conversation.

### Events

The stream starts after `Last-Event-ID`, or after `?starting_after=`, and without either after the
last event written when it connects. A page takes `?starting_after=`, `0` by default, and `?limit=`,
up to 500. Where events after the sequence have been dropped, either answers `410` with the oldest
one still held; read the snapshot and follow from its `sequence`. See
[Events](/reference/events/) for every event.

### Exports

```http
GET /v1/exports/siem?limit=500

POST /v1/exports/siem
{"next": "eyJhY21lL3RyaWFnZSI6NDF9"}
```

An export is a cursor of the caller's own, kept on the server under the name it gives, over every
log it may read: each agent's it may `read`, a removed agent's included, and the audit where it
reaches every agent. A page answers the events after the cursor and leaves it there, so reading
again answers them again; posting the page's `next` moves it past them, once they are safely kept.
`gaps` names each log trimmed past the cursor, which was read from its oldest event.

### Messages

```http
POST /v1/agents/acme/triage/messages

{"id": "msg_01", "parts": [{"type": "text", "content": "What's on fire?"}]}
```

`content` in place of `parts` is the text alone. `id` is optional, and a message sent again under
the same `id` is taken once. The answer names it: `{"message": {"id": "msg_01"}}`.

### Decisions

```http
POST /v1/agents/acme/triage/decisions

{"decisions": [{"id": "toolu_01", "decision": "reject", "reason": "Not this quarter."}]}
```

Each decision names a call the agent waits on, by its `id`, and is `approve` or `reject`. A
rejection's `reason` is what the model is told in place of the call's answer. An approval's `note`,
as in `{"id": "toolu_01", "decision": "approve", "note": "Only this once."}`, is what it reads
beside the answer, and never changes the call, which runs as the model wrote it. The decisions are
taken together and recorded as the caller's. The answer lists each call as `approved` or `rejected`;
`409` where the agent isn't waiting on one of them.

### Triggers

```http
PUT /v1/agents/acme/triage/triggers/sweep

{"every": "*/30 * * * *", "prompt": "Check the incident queue."}
```

A trigger takes the keys of an [agent file's
triggers](/reference/agent-files/#triggers). It is part of the agent's definition: a
definition put again lists every trigger the agent has.

### Webhooks

A service's request to `/v1/hooks/{key}/{trigger}` carries no token, but the trigger's secret, as
`Authorization: Bearer`, at the end of the path, or as a Standard Webhooks signature. It answers
`202`, and whether the agent was asked or had been asked about the same request already; `404` where
the agent has no such trigger or the signature doesn't match, so a sender learns nothing of the
triggers it can't sign for; and `503` where it can't be delivered now, so a sender that tries again
delivers it later.

### Channels

A chat app's request to `/v1/channels/{channel}/{path}`, such as Slack's events at
`/v1/channels/slack/events` and button presses at `.../actions`, carries no token. The daemon
hands it, as it was sent, to the channel `config.yaml` names, which checks it by its signature and
answers as the chat app expects; `404` where no channel of that name takes requests. See
[Slack](/channels/slack/).

### Connections

```http
GET /v1/connections?prefix=acme/@jon/

{"connections": [{"provider": "github", "held_by": "person"},
                 {"provider": "linear"}]}
```

```http
POST /v1/connections/linear?prefix=acme/@jon/

{"provider": "linear", "connected": false,
 "authorization": {"url": "https://linear.app/oauth/authorize?…"}}
```

`prefix` names the owner: a person, `acme/@jon/`, or an org, `acme/`. The token must reach the
owner's agents. The account is held once the person has authorized it at the link. A secret's value
is never answered.

### Servers

```http
POST /v1/servers?prefix=acme/@jon/

{"name": "crm", "url": "https://mcp.crm.example/mcp",
 "auth": {"secret": {"name": "crm-key"}}}

{"server": "crm", "connected": true}
```

```http
GET /v1/servers?prefix=acme/@jon/

{"servers": [{"name": "crm", "url": "https://mcp.crm.example/mcp", "auth": "secret"}]}
```

`prefix` names the owner, as for connections. A server serves its owner's agents alone, and each of its tools arrives as `crm__tool`. It is reached over
Streamable HTTP at an `https` URL whose host has public addresses, and signs in with nothing,
`{"none": {}}`, in a browser as the server's own authorization server asks, `{"oauth": {"scopes":
[...]}}`, which answers the link to sign in at, or a secret the owner keeps in the vault,
`{"secret": {"name": ...}}`, sent as `Authorization: Bearer` unless `header` and `scheme` say
otherwise. Removing one signed in to forgets its token. `only` and `except` list the
server's own names of the tools to take or leave. Every tool the server does not mark `readOnlyHint`
waits on a person unless a policy allows it, and what it answers is labelled `outside`. A name a
server of the deployment's own that serves the owner names its tools with already is a `409`.

### The deployment

```http
GET /v1/deployment/nodes

{"nodes": [{"name": "wardrik@box1", "agents": 12}], "asleep": 40}
```

```http
GET /v1/deployment/audit?starting_after=120&limit=50

{"changes": [{"type": "wardrik.agent.defined", "subject": "agents/acme/triage", …}]}
```

A change in the audit is a CloudEvent, as an agent's events are, whose `data.actor` is who made it,
and `data.assumed_by`, where anyone acted for them, who did, first to last.
A page asked for before the oldest change kept is a `gap`, as an agent's events are.

### Tool workers

A tool worker is an MCP server that dials in: it opens a WebSocket to `/v1/workers` with a token,
Wardrik lists its tools and calls them over it, and it answers each call from its own process. An
agent whose tools include `workers/*` is offered the tools of every worker whose token reaches its
key, as `workers/<name>`. A call carries the agent it is for as `_meta.agent`, its run as
`_meta.run`, and its idempotency key as `_meta.idempotencyKey`. A worker that answers with
`_meta.costUsd` says what the call cost in US dollars, which a budget counts. See
[Tools in your app](/build/tool-workers/).

## Every response

Carries a `Request-Id` header, the caller's own where it sent one. An error is
`{"error": {"type": …, "message": …}}`. A request that changes something is recorded in the audit
with the caller.


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

The body of PUT /v1/agents/{key}, and the definition GET /v1/agents/{key}/definition answers, an agent file's included. An agent file's frontmatter takes the same keys, with its body as instructions, and name, org and user besides.

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
| `retries` | object |  | How a turn tries a failed model call again, after a random wait of up to a second that doubles each time. A 4xx answer other than 408, 425 and 429 is not tried again. The host's defaults hold where this is absent. |
| `retries.attempts` | integer |  | How many times a failed model call is tried again: 6 unless set. 0 never tries again. |
| `retries.max_wait` | integer |  | The longest wait between tries, in seconds: 60 unless set. |
| `retries.on_exhausted` | string |  | What happens once the tries are spent: ask a person whether to try again, or fail the turn. ask unless set. One of `ask`, `fail`. |
| `compaction` | `false` or object |  | When the agent summarises its older history, as shares of the model's window; false never does. |
| `triggers` | array of object |  | The triggers that ask the agent something when they come round, each with a prompt or a prompt_file. A definition put again replaces them all, and PUT and DELETE /v1/agents/{key}/triggers/{trigger} change one. Any other field is the source's that the trigger watches, which one of them names; without one, it asks on every run. A trigger on a clock has every, and a timezone a cron expression is read in; a webhook has webhook in its place, holding its secret and how a request is verified, and is sent requests at POST /v1/hooks/{key}/{trigger}. |
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
| `activity` | [activity](/reference/events/#activity) | yes |  |
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
| `authorization` | [authorization](/reference/http-api/#authorization) |  | Where to authorize it, where it is not held yet. |

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

### `definition_read`

What GET /v1/agents/{key}/definition answers: the definition last put, as it was sent, and the tools it names that offer nothing yet.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `definition` | [agent_definition](/reference/http-api/#agent_definition) | yes |  |
| `missing` | array of string | yes | The tools the definition names that offer nothing yet, such as server/* for an MCP server its owner has not added. Each offers its tools once what it names is there, without the definition being put again. |

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
| `events` | array of [event](/reference/events/#the-envelope) | yes | Oldest first within each log; each event's source names its log, and its sequence its place there. |
| `next` | string | yes | What POST /v1/exports/{name} takes, as {"next": …}, to move the cursor past these events. |
| `gaps` | array of object | yes | Each log trimmed past the cursor, which was read from its oldest event. |

### `nodes`

The deployment's nodes, each with how many agents run on it, and how many agents sleep on none: what GET /v1/deployment/nodes answers.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `nodes` | array of object | yes |  |
| `asleep` | integer | yes | How many agents sleep, on no node, until something asks them. |

### `server_added`

What POST /v1/servers answers: that the owner's agents can call the server now, or where someone signs in to it first.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `server` | string | yes | The server's name. |
| `connected` | boolean | yes | Whether its agents can call it now. |
| `authorization` | [authorization](/reference/http-api/#authorization) |  | Where to sign in to it, where someone has to first. |

### `servers`

The MCP servers an owner added for their agents: what GET /v1/servers answers.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `servers` | array of object | yes |  |

### `token`

An API token as the server keeps it, never its secret.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | yes | What revoking it takes. |
| `name` | string | yes |  |
| `principal` | [principal](/reference/events/#principal) | yes | Whom it acts for: whoever made it. |
| `statements` | array of [statement](/reference/events/#statement) | yes | What it allows, on what; anything none states is denied. |
| `policy` | string |  | The policy every agent it defines runs under, ahead of the agent's own, by its name: what IAM calls a permissions boundary. Absent where it names none. |
| `expires` | string (date-time) |  | When it stops working. |
| `created_at` | string (date-time) | yes |  |

### `token_issued`

A token just made, and the secret that presents it, given this once: what POST /v1/tokens answers.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `token` | [token](/reference/http-api/#token) | yes |  |
| `secret` | string | yes | What a request presents, as Authorization: Bearer secret. |

### `tokens`

Every API token, oldest first: what GET /v1/tokens answers.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `tokens` | array of [token](/reference/http-api/#token) | yes |  |

### `trigger`

A trigger as it was put, the trigger field of what PUT /v1/agents/{key}/triggers/{trigger} answers. A trigger on a clock has every, missed and jitter, and a cron expression its timezone, and any other field is the source's that it watches, which one of them names; without one, it asks on every run. A webhook has webhook, its secret and how a request is verified, and asks as each request arrives.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes |  |
| `every` | string |  | A cron expression, or a duration such as 30m. |
| `timezone` | string |  | The time zone a cron expression in every is read in, by its IANA name, as Europe/Berlin; Etc/UTC where it is left out. A duration counts elapsed time and takes none. |
| `prompt` | string | yes | What the agent is asked each time. |
| `overlap` | string | yes | What a firing does while a run is still going: skip it, or queue its prompt. One of `skip`, `queue`. |
| `missed` | string |  | What a trigger does about the firings it missed while down. One of `run_once`, `skip`. |
| `jitter` | integer |  | Up to this many seconds of delay, chosen at random each time. |

### `trigger_definition`

The body of PUT /v1/agents/{key}/triggers/{trigger}, with a prompt or a prompt_file. A trigger on a clock has every, and a cron expression a timezone where it is not UTC; overlap is skip, missed is run_once and jitter is 0 where they are left out, and any other field is the source's that it watches, which one of them names; without one, it asks on every run. A webhook has webhook in place of every, holding its secret, as ${NAME}, and verify, shared or standard; it is sent requests at POST /v1/hooks/{key}/{trigger}, and its overlap is queue where it says none.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `every` | string |  | A cron expression, or a duration such as 30m. |
| `timezone` | string |  | The time zone a cron expression in every is read in, by its IANA name, as Europe/Berlin; Etc/UTC where it is left out. A duration counts elapsed time and takes none. |
| `prompt` | string |  | What the agent is asked each time. |
| `prompt_file` | string |  | In place of prompt, a file in the agent's tree: each time, the agent is asked to read it and do what it says. tools names files to read it with. |
| `overlap` | string |  | What a firing does while a run is still going: skip it, or queue its prompt. One of `skip`, `queue`. |
| `missed` | string |  | What a trigger does about the firings it missed while down. One of `run_once`, `skip`. |
| `jitter` | integer |  | Up to this many seconds of delay, chosen at random each time. |
