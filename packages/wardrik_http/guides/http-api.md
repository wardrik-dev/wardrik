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
`/v1/hooks/`, which its trigger checks instead, a chat app's to `/v1/channels/`, which its
channel checks, and a browser's that a provider sends back after a sign-in, to `/oauth/` on the
daemon. `wardrik token create` makes one from a shell on the server, and `/v1/tokens`
over the API:

```sh
wardrik token create ci --resource 'acme/agent/*' --role reader,messenger,definer --policy careful
wardrik token create watcher --resource 'acme/@ops/*' --role reader
wardrik token create one --resource acme/@jon/agent/triage --resource 'acme/@jon/agent/triage/*' \
  --role owner --expires 30d
wardrik token create laptop --resource '*' --role owner
wardrik token list
wardrik token revoke 3f9a61c0d4e2
```

A token an earlier release made doesn't read; make it again. A token's statements each allow some
actions, named for what a route does, such as `agent.ask`, on the resources a pattern covers. A resource is named as IAM names one: `acme/agent/triage` is
acme's agent `triage`, the agent ID `acme/triage`; `acme/agent/triage/thread/1696.1234` is it
answering for `1696.1234`; `acme/@jon/server/crm` and `acme/@jon/secret/github` are jon's MCP
server and account; `deployment/token/…` is a token. In a pattern, `*` matches anything, `/` too,
and `?` one character: `acme/agent/*` is acme's own agents with their threads, `acme/*` everything
of acme's and its users', and `*` everything. Nothing is implied: an agent and its threads are
`acme/agent/triage` and `acme/agent/triage/*`. Anything no statement allows is denied. An agent no
statement reaches is answered as one that doesn't exist, `404`, and an action not allowed on one it
reaches is refused with `403`. A role is a named set of actions:

| Role | Routes |
| --- | --- |
| `reader` | listing agents, snapshots, definitions, events, the tool calls an agent is running, the calls agents wait on, connections and servers |
| `messenger` | messages, cancelling, and clearing the conversation |
| `approver` | decisions, and authorization links |
| `definer` | putting, starting, stopping and deleting agents and triggers, stopping a tool call, connecting accounts, and adding and removing servers |
| `worker` | `/v1/workers` |
| `owner` | every route; on `*` or `deployment/*`, the deployment and `/v1/tokens` too |

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
| `GET /v1/agents` | the agents `?resource=` covers, as `acme/agent/*`, or those the token's one resource covers |
| `POST /v1/agents/cancel?resource=` | stops what every agent the pattern covers is doing, `202` |
| `DELETE /v1/agents?resource=` | removes every agent the pattern covers but those agent files declare; answers which went, which stayed and why |
| `GET /v1/interrupts` | the calls agents `?resource=` covers, or those the token's one resource covers, wait on a person for |
| `GET /v1/events` | the events of the agents each `?resources=` covers, as server-sent events with `Accept: text/event-stream`, otherwise a page as JSON; see [Events](#events) |
| `GET /v1/events/head` | the cursor where the log of each agent `?resources=` covers stands, `{"cursor": ...}` |
| `GET /v1/agents/{key}` | the agent's snapshot, with `cursor`, where its log stands |
| `PUT /v1/agents/{key}` | starts the agent a definition describes, or brings the one running to it; answers its snapshot |
| `GET /v1/agents/{key}/definition` | the definition last put, as it was sent, with the tools it names that offer nothing yet as `missing` |
| `DELETE /v1/agents/{key}` | stops the agent and deletes everything it had, its definition and triggers included, `204`; `409` where an agent file declares it |
| `GET /v1/agents/{key}/events` | its log, as `GET /v1/events` reads it |
| `POST /v1/agents/{key}/messages` | queues a message for the agent to answer, `202` |
| `POST /v1/agents/{key}/decisions` | approves or rejects calls the agent is waiting on, together |
| `GET /v1/agents/{key}/interrupts/{id}/authorization` | where a person authorizes a call waiting with reason `authorization` |
| `POST /v1/agents/{key}/cancel` | stops what the agent is doing, and drops what is queued, `202` |
| `GET /v1/agents/{key}/calls` | the tool calls the agent is running, each with how long it has run; `404` while it sleeps |
| `DELETE /v1/agents/{key}/calls/{call}` | stops one tool call the agent is running, `204`: the model is answered with an error, and the turn goes on |
| `POST /v1/agents/{key}/spawn` | starts the agent; with `{"node": ...}`, on that node, to a token over `deployment/*` |
| `POST /v1/agents/{key}/stop` | stops the agent, keeping its conversation, so it sleeps until something asks it; answers it, asleep |
| `POST /v1/agents/{key}/move` | starts the agent again on `{"node": ...}`, with its conversation, to a token over `deployment/*` |
| `DELETE /v1/agents/{key}/conversation` | empties the agent's conversation, and the labels of what it held, and answers its snapshot; `409` while it runs a turn or waits on a person |
| `PUT /v1/agents/{key}/triggers/{trigger}` | sets or changes a trigger, and answers it; `404` where no definition is kept, `409` where an agent file declares the agent |
| `DELETE /v1/agents/{key}/triggers/{trigger}` | stops the trigger and deletes it, and answers it as it was |
| `POST /v1/hooks/{key}/{trigger}`, or `.../{trigger}/{secret}` | delivers a service's request to a webhook trigger; see [Webhooks](#webhooks) |
| `POST /v1/channels/{channel}/{path}` | delivers what a chat app, such as Slack, sends a channel; see [Channels](#channels) |
| `GET /v1/connections?owner=` | the accounts `owner` is offered, and whether each is their own, one the deployment shares, or none |
| `POST /v1/connections/{provider}` | connects an account: where to authorize it, or that it is held already |
| `DELETE /v1/connections/{provider}` | forgets the account, so the next call that needs it asks again, and answers it as it was held |
| `GET /v1/servers?owner=` | the MCP servers `owner` added for their agents |
| `POST /v1/servers?owner=` | adds an MCP server for the owner's agents, `201`: that they can call it now, or where to sign in to it first |
| `DELETE /v1/servers/{name}?owner=` | removes the server, so the owner's agents can no longer call it, and answers it as it was |
| `POST /v1/deployment/reload` | reads the agent and policy files and every definition again, on the node that answers, and answers that node |
| `GET /v1/deployment/nodes` | the deployment's nodes, each with how many agents run on it, and how many sleep |
| `GET /v1/deployment/audit` | a page of what people changed across the deployment, after `?starting_after=` |
| `GET /v1/tokens` | every token, oldest first, never a secret |
| `POST /v1/tokens` | makes a token from its `name`, `resources`, `roles`, `policy` and `expires_in`, `201`, with its `secret`, given this once |
| `DELETE /v1/tokens/{id}` | revokes the token, and answers it as it was |
| `GET /v1/workers` | a WebSocket a tool worker holds open, to offer tools and answer calls to them |

The `/v1/deployment` and `/v1/tokens` routes are for an `owner` token on `*` or `deployment/*`
alone.

A cancel by a pattern answers `{"cancelled": [...]}`, and a removal
`{"forgotten": [...], "kept": [{"id": ..., "why": ...}], "failed": [...]}`.

wardrik_core's `priv/openapi.json` is every route in OpenAPI 3.1: what each takes and
answers, and the function of `Wardrik` it calls. A client generator in any language reads
`priv/openapi.bundled.json`, the same with every schema in it.

[Bodies](#bodies), below, lists what each route takes and answers. The TypeScript SDK's types
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

```http
GET /v1/events?resources=acme/agent/*&types=wardrik.run.completed
Accept: text/event-stream

id: eyJhY21lL2FnZW50L3RyaWFnZSI6NDF9
data: {"specversion":"1.0","type":"wardrik.run.completed",…}
```

`?resources=` is a pattern, given once for each, and `?types=` an event type; without them, every
agent whose events the token reads, and every type. A `wardrik.events.dropped` comes whatever the
types. An event's `id` is a cursor: where the reader
has got to in each agent's log. A stream starts after `Last-Event-ID` or `?after=`, and without
either at what is written next; a page starts after `?after=`, at the start by default, takes
`?limit=` up to 500, and answers `{"events": [...], "next": ...}`, the cursor after them. A
snapshot's `cursor`, and a message's, read on from there. The server keeps no reader's place.

`GET /v1/events/head` answers the cursor at the head of every log the patterns cover. A reader
that starts from what is written next starts from it, so the cursor it keeps names every agent it
reads, and resumes in each. A stream opened without a cursor starts there itself.

A cursor is about 50 bytes for each agent it names, so a `Last-Event-ID` holds the place of 150 to
200 agents; read more as pages. Where a log was trimmed past the cursor, a
`wardrik.events.dropped` names the sequence asked after and the oldest the log holds, and reading
goes on from there. See [Events](https://docs.wardrik.dev/reference/events/) for every event.

### Messages

```http
POST /v1/agents/acme/triage/messages

{"id": "msg_01", "parts": [{"type": "text", "content": "What's on fire?"}]}
```

`content` in place of `parts` is the text alone. `id` is optional, and a message sent again under
the same `id` is taken once. The answer names it, with the cursor its turn is read after:
`{"message": {"id": "msg_01", "cursor": "eyJhY21lL2FnZW50L3RyaWFnZSI6NDF9"}}`.

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

### Channels

A chat app's request to `/v1/channels/{channel}/{path}`, such as Slack's events at
`/v1/channels/slack/events` and button presses at `.../actions`, carries no token. The daemon
hands it, as it was sent, to the channel `config.yaml` names, which checks it by its signature and
answers as the chat app expects; `404` where no channel of that name takes requests. See
[Slack](https://docs.wardrik.dev/channels/slack/).

### Connections

```http
GET /v1/connections?owner=acme/@jon

{"connections": [{"provider": "github", "held_by": "own"},
                 {"provider": "linear", "held_by": "none"}]}
```

```http
POST /v1/connections/linear?owner=acme/@jon

{"provider": "linear", "connected": false,
 "authorization": {"url": "https://linear.app/oauth/authorize?…"}}
```

`owner` names a person, `acme/@jon`, or an org, `acme`. The token must reach the owner's
agents. `held_by` is what a call of the owner's agents would use: `own`, `shared` where they
hold none and the deployment shares one, or `none`; an org's account is not its people's. The
account is held once the person has authorized it at the link. A secret's value is never
answered.

### Servers

```http
POST /v1/servers?owner=acme/@jon

{"name": "crm", "url": "https://mcp.crm.example/mcp",
 "auth": {"secret": {"name": "crm-key"}}}

{"server": "crm", "connected": true}
```

```http
GET /v1/servers?owner=acme/@jon

{"servers": [{"name": "crm", "url": "https://mcp.crm.example/mcp", "auth": "secret"}]}
```

`owner` names the owner, as for connections. A server serves its owner's agents alone, and each of its tools arrives as `crm__tool`. It is reached over
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
[Tools in your app](https://docs.wardrik.dev/build/tool-workers/).

## Every response

Carries a `Request-Id` header, the caller's own where it sent one. An error is
`{"error": {"type": …, "message": …}}`. A request that changes something is recorded in the audit
with the caller.
