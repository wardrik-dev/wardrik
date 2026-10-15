# HTTP API

Wardrik's agents over HTTP: a versioned JSON API, and each agent's event log as server-sent events a
client resumes after any disconnect.

The daemon serves it on `127.0.0.1:4747`, and `config.yaml` moves it:

```yaml
http:
  port: 4747
  ip: 0.0.0.0     # every interface; loopback unless set
```

See [Use the HTTP API](https://docs.wardrik.dev/build/http-api/) for a walk through it, and the
TypeScript SDK for a client.

## Tokens

Every request presents a token, as `Authorization: Bearer wardrik_…`, except a webhook's to
`/v1/hooks/`, which its trigger checks instead. Tokens are made from a shell on the server, never
over the API:

```sh
wardrik token create ci --scope acme/ --policy careful
wardrik token create watcher --scope acme/@ops/ --can read
wardrik token create one --scope acme/@jon/triage --policy careful
wardrik token create laptop --all --unlimited --for jon
wardrik token list
wardrik token revoke 3f9a61c0d4e2
```

A token reaches the agents under its scope, a key prefix that ends at a segment, and takes the
actions it was made with, every action unless fewer were given. An agent outside its scope is
answered as one that doesn't exist, `404`, and an action it wasn't given is refused with `403`.

| Action | Routes |
| --- | --- |
| `read` | listing agents, snapshots, definitions, events, connections and servers; the deployment's nodes and audit |
| `message` | messages, cancelling, and clearing the conversation |
| `decide` | decisions, and authorization links |
| `define` | putting and deleting agents and triggers, connecting accounts, adding and removing servers, and reloading the deployment |
| `serve` | `/v1/workers` |

A token acts for the person it was made `--for`, or for itself, and a decision made with it is
recorded as theirs. A revoked token is refused, and the streams and worker sockets open on it are
closed, at once on every node the revocation reaches and within 15 seconds on one it doesn't.

A token that can `define` carries a ceiling: a policy every agent it defines is held to ahead of the
definition's own, so a definition can narrow what its ceiling allows and never widen it. It is made
with `--policy`, or with none said outright with `--unlimited`.

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
| `PUT /v1/agents/{key}` | starts the agent a definition describes, `201`, or brings the one running to it, `200`; answers its snapshot |
| `GET /v1/agents/{key}/definition` | the definition last put, as it was sent |
| `DELETE /v1/agents/{key}` | stops the agent and deletes everything it had, its definition and triggers included; `409` where an agent file declares it |
| `GET /v1/agents/{key}/events` | its log as server-sent events, with `Accept: text/event-stream`; otherwise a page of it as JSON |
| `POST /v1/agents/{key}/messages` | queues a message for the agent to answer, `202` |
| `POST /v1/agents/{key}/decisions` | approves or rejects calls the agent is waiting on, together |
| `GET /v1/agents/{key}/interrupts/{id}/authorization` | where a person authorizes a call waiting with reason `authorization` |
| `POST /v1/agents/{key}/cancel` | stops what the agent is doing, and drops what is queued, `202` |
| `POST /v1/agents/{key}/spawn` | starts the agent; with `{"node": ...}`, on that node, to a token over every agent |
| `POST /v1/agents/{key}/stop` | stops the agent, keeping its conversation, so it sleeps until something asks it |
| `POST /v1/agents/{key}/move` | starts the agent again on `{"node": ...}`, with its conversation, to a token over every agent |
| `DELETE /v1/agents/{key}/conversation` | empties the agent's conversation, and the labels of what it held, `204`; `409` while it runs a turn or waits on a person |
| `PUT /v1/agents/{key}/triggers/{trigger}` | sets a trigger, `201`, or changes it, `200`; `404` where no definition is kept, `409` where an agent file declares the agent |
| `DELETE /v1/agents/{key}/triggers/{trigger}` | stops the trigger and deletes it, `204` |
| `POST /v1/hooks/{key}/{trigger}`, or `.../{trigger}/{secret}` | delivers a service's request to a webhook trigger; see [Webhooks](#webhooks) |
| `GET /v1/exports/{name}` | a page of every log the caller may read, after the export's cursor |
| `POST /v1/exports/{name}` | moves the export's cursor to a page's `next`, `204` |
| `DELETE /v1/exports/{name}` | deletes the export's cursor, so it reads from the start again, `204` |
| `GET /v1/connections` | the accounts the caller's org is offered, and whether they, the org or the deployment holds each |
| `POST /v1/connections/{provider}` | connects an account: where to authorize it, or that it is held already |
| `DELETE /v1/connections/{provider}` | forgets the account, so the next call that needs it asks again, `204` |
| `GET /v1/servers` | the MCP servers the caller added for their own agents |
| `POST /v1/servers` | adds an MCP server for the caller's agents, `201`: that they can call it now, or where to sign in to it first |
| `DELETE /v1/servers/{name}` | removes the server, so the caller's agents can no longer call it, `204` |
| `POST /v1/deployment/reload` | has every node read its agent and policy files again, and answers those nodes |
| `GET /v1/deployment/nodes` | the deployment's nodes, each with how many agents run on it, and how many sleep |
| `GET /v1/deployment/audit` | a page of what people changed across the deployment, after `?starting_after=` |
| `GET /v1/workers` | a WebSocket a tool worker holds open, to offer tools and answer calls to them |

The `/v1/deployment` routes are for a token over every agent alone.

A route that changes something answers what it would do, and does nothing, with `?plan=true`: a
cancel answers `{"cancelling": [...]}`, and a removal
`{"forgetting": [...], "keeping": [{"id": ..., "why": ...}]}`. Done, a cancel answers
`{"cancelled": [...]}`, and a removal `{"forgotten": [...], "kept": [...], "failed": [...]}`.

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

A definition takes the keys of an [agent file](`e:wardrik_daemon:agent-files.html`), with
`instructions` as its system prompt. The daemon keeps it, so `GET …/definition` answers it, and
refuses a key an agent file declares with `409`. An agent brought to a new definition keeps its
conversation.

### Events

The stream starts after `Last-Event-ID`, or after `?starting_after=`, and without either after the
last event written when it connects. A page takes `?starting_after=`, `0` by default, and `?limit=`,
up to 500. Where events after the sequence have been dropped, either answers `410` with the oldest
one still held; read the snapshot and follow from its `sequence`. See
[Events](https://docs.wardrik.dev/reference/events/) for every event.

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
triggers](`e:wardrik_daemon:agent-files.html#triggers`). It is part of the agent's definition: a
definition put again lists every trigger the agent has.

### Webhooks

A service's request to `/v1/hooks/{key}/{trigger}` carries no token, but the trigger's secret, as
`Authorization: Bearer`, at the end of the path, or as a Standard Webhooks signature. It answers
`202`, and whether the agent was asked or had been asked about the same request already; `404` where
the agent has no such trigger or the signature doesn't match, so a sender learns nothing of the
triggers it can't sign for; and `503` where it can't be delivered now, so a sender that tries again
delivers it later.

### Connections

```http
GET /v1/connections

{"connections": [{"provider": "github", "held_by": "person"},
                 {"provider": "linear"}]}
```

```http
POST /v1/connections/linear

{"provider": "linear", "connected": false,
 "authorization": {"url": "https://linear.app/oauth/authorize?…"}}
```

A caller's connections are its person's, within the org its token reaches: the user its scope names,
else the user it was made `--for`. With `?owner=org` they are the org's, for a token that may
`define` under the org. The account is held once the person has authorized it at the link. A
secret's value is never answered.

### Servers

```http
POST /v1/servers

{"name": "crm", "url": "https://mcp.crm.example/mcp",
 "auth": {"secret": {"name": "crm-key"}}}

{"server": "crm", "connected": true}
```

```http
GET /v1/servers

{"servers": [{"name": "crm", "url": "https://mcp.crm.example/mcp", "auth": "secret"}]}
```

A caller's servers are its person's, as connections are, and with `?owner=org` the org's. A server
serves its owner's agents alone, and each of its tools arrives as `crm__tool`. It is reached over
Streamable HTTP at an `https` URL whose host has public addresses, and signs in with nothing,
`{"none": {}}`, or a secret the owner keeps in the vault, `{"secret": {"name": ...}}`, sent as
`Authorization: Bearer` unless `header` and `scheme` say otherwise. `only` and `except` list the
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

A change in the audit is a CloudEvent, as an agent's events are, whose `data.actor` is who made it.
A page asked for before the oldest change kept is a `gap`, as an agent's events are.

### Tool workers

A tool worker is an MCP server that dials in: it opens a WebSocket to `/v1/workers` with a token,
Wardrik lists its tools and calls them over it, and it answers each call from its own process. An
agent whose tools include `workers/*` is offered the tools of every worker whose token reaches its
key, as `workers/<name>`. A call carries the agent it is for as `_meta.agent`, its run as
`_meta.run`, and its idempotency key as `_meta.idempotencyKey`. A worker that answers with
`_meta.costUsd` says what the call cost in US dollars, which a budget counts. See
[Tools in your app](https://docs.wardrik.dev/build/tool-workers/).

## Every response

Carries a `Request-Id` header, the caller's own where it sent one. An error is
`{"error": {"type": …, "message": …}}`. A request that changes something is recorded in the audit
with the caller.
