---
title: "HTTP API"
description: "Wardrik's agents over HTTP: a versioned JSON API, and each agent's event log as server-sent events a client resumes after any disconnect."
sidebar:
  order: 5
---

Wardrik's agents over HTTP: a versioned JSON API, and each agent's event log as server-sent events a
client resumes after any disconnect.

```sh
curl -H "Authorization: Bearer $WARDRIK_TOKEN" http://127.0.0.1:4747/v1/agents
```

The daemon serves it on `127.0.0.1:4747`, and `config.yaml`'s [`http`](/reference/config/#http)
moves it:

```yaml
http:
  port: 4747
  ip: 0.0.0.0     # every interface; loopback unless set
```

See [Use the HTTP API](/build/http-api/) for a walk through it, and the TypeScript SDK for a client.

## Tokens

Every request presents a token, as `Authorization: Bearer wrk_…`. These take none:

- a service's request to a webhook trigger, at `/v1/hooks/`, which the trigger checks;
- a chat app's request, at `/v1/channels/`, which its channel checks;
- a browser a provider sends back after a sign-in, at `/oauth/`.

`wardrik token create` makes a token, as does `POST /v1/tokens`:

```sh
wardrik token create ci --resource 'acme/agent/*' --role reader,messenger,definer --policy careful
wardrik token create watcher --resource 'acme/@ops/*' --role reader
wardrik token create one --resource acme/@jon/agent/triage --resource 'acme/@jon/agent/triage/*' \
  --role owner --expires 30d
wardrik token create laptop --resource '*' --role owner
wardrik token ls
wardrik token revoke 3f9a61c0d4e2
```

A token holds statements. Each allows some actions, such as `agent.ask`, on the resources a pattern
covers. Anything no statement allows is denied.

### Resources

A resource is named as IAM names one:

| Resource | Names |
| --- | --- |
| `acme/agent/triage` | acme's agent `triage`, the agent ID `acme/triage` |
| `acme/@jon/agent/triage` | jon's agent `triage`, the agent ID `acme/@jon/triage` |
| `acme/agent/triage/conversation/C1-1696.1234` | one of its conversations, as a Slack thread's |
| `acme/mcp_server/crm` | an MCP server acme added |
| `acme/@jon/connection/github` | jon's GitHub account |
| `acme/@jon/secret/GITHUB_TOKEN` | a secret jon sealed |
| `acme/ceiling` | acme's ceilings |
| `deployment` | the deployment: its nodes, audit, reloads, moves and tokens |

In a pattern, `*` matches anything, `/` too, and `?` one character:

- `acme/agent/*` is acme's own agents, with their conversations;
- `acme/*` is everything of acme's and its users';
- `*` is everything.

Nothing is implied: an agent and its conversations are `acme/agent/triage` and
`acme/agent/triage/*`. An agent no statement reaches is answered as one that doesn't exist, `404`.
An action not allowed on one it reaches is refused with `403`.

### Roles

A role is a named set of actions:

| Role | Actions |
| --- | --- |
| `reader` | `agent.read`, `agent.events`, `connection.read`, `mcp_server.read`, `ceiling.read` |
| `messenger` | `agent.ask`, `agent.cancel`, `agent.clear` |
| `approver` | `agent.decide` |
| `definer` | `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget`, `connection.connect`, `mcp_server.add` |
| `worker` | `agent.serve`, offering tools to the agents it covers over `/v1/workers` |
| `owner` | every action, `secret.read`, `secret.put` and the `deployment.*` actions included |

The [routes](#routes) table names the action each route needs.

### Lifetime and boundary

- A token acts for whoever made it, and a change made with it is recorded as theirs.
- It is no wider than its maker: its actions, resources, policy and expiry are within theirs.
- It works for 90 days, or as long as `--expires` or `expires_in` says. An expired token is refused
  with `401`.
- A revoked token is refused at once. The streams and worker sockets open on it close at their
  next keepalive, within 15 seconds. An agent it defined keeps running.
- Its policy is one every agent it defines runs under, ahead of the definition's own: what IAM
  calls a permissions boundary. It is set with `--policy`, or `policy` over the API, and is the
  maker's own where neither names one.

## Agents in paths

An agent's ID is its path under `/v1/agents/`, slashes and all. A conversation follows it as
`conversations/ID`.

| Agent | Path |
| --- | --- |
| `acme/triage` | `/v1/agents/acme/triage` |
| `acme/@jon/triage` | `/v1/agents/acme/@jon/triage` |
| the conversation `acme/triage/C1-1696.1234` | `/v1/agents/acme/triage/conversations/C1-1696.1234` |

- A client percent-encodes each segment on its own and joins them with `/`. `@` may be sent as it
  is or as `%40`.
- A segment that decodes to a `/`, as `%2F` does, is refused with `400`.
- No segment holds a `:`.
- The `id` the API answers an agent with is its ID.

## Routes

| Route | Operation | Action | Answers |
| --- | --- | --- | --- |
| `GET /v1/agents` | `agents.list` | `agent.read` | the agents each `?resources=` pattern covers, or every agent the token reaches |
| `DELETE /v1/agents?resources=` | `agents.forget` | `agent.forget` | removes every agent the patterns cover but those agent files declare; answers which went, which stayed and why |
| `POST /v1/agents/cancel?resources=` | `agents.cancel` | `agent.cancel` | stops what every agent the patterns cover is doing, `202`; answers which |
| `GET /v1/interrupts` | `interrupts.list` | `agent.read` | the calls the agents `?resources=` covers wait on a person for |
| `GET /v1/events` | `events.list` | `agent.events` | the events of the agents `?resources=` covers; see [Events](#events) |
| `GET /v1/events/head` | `events.head` | `agent.events` | the cursor where those agents' logs stand |
| `GET /v1/agents/{agent}` | `agent.read` | `agent.read` | the agent's snapshot, with `cursor`, where its log stands |
| `PUT /v1/agents/{agent}` | `agent.define` | `agent.define` | starts the agent a definition describes, or brings the one running to it; answers its snapshot |
| `GET /v1/agents/{agent}/definition` | `agent.definition` | `agent.read` | the definition last put, as it was sent, with the tools it names that offer nothing yet as `missing` |
| `DELETE /v1/agents/{agent}` | `agent.forget` | `agent.forget` | stops the agent and deletes its conversation, definition and triggers, `204`; `409` where an agent file declares it |
| `GET /v1/agents/{agent}/events` | `agent.events` | `agent.events` | its log, as `GET /v1/events` reads it |
| `GET /v1/agents/{agent}/timeline` | `agent.timeline` | `agent.events` | its conversation as a person reads it |
| `GET /v1/agents/{agent}/runs` | `agent.runs` | `agent.events` | what its runs did and cost, newest first, with totals |
| `POST /v1/agents/{agent}/messages` | `agent.ask` | `agent.ask` | queues a message for the agent to answer, `202` |
| `POST /v1/agents/{agent}/decisions` | `agent.decide` | `agent.decide` | approves or rejects calls the agent waits on, together |
| `POST /v1/agents/{agent}/interrupts/{interrupt}/approve` | `agent.approve` | `agent.decide` | approves one call, with an optional `note` |
| `POST /v1/agents/{agent}/interrupts/{interrupt}/deny` | `agent.deny` | `agent.decide` | rejects one call, with an optional `reason` |
| `GET /v1/agents/{agent}/interrupts/{interrupt}/authorization` | `agent.authorization` | `agent.decide` | where a person authorizes a call waiting with reason `authorization` |
| `POST /v1/agents/{agent}/cancel` | `agent.cancel` | `agent.cancel` | stops what the agent is doing, and drops what is queued, `202` |
| `GET /v1/agents/{agent}/calls` | `agent.calls` | `agent.read` | the tool calls the agent is running, each with how long it has run; `404` while it sleeps |
| `DELETE /v1/agents/{agent}/calls/{call}` | `agent.kill` | `agent.cancel` | stops one tool call, `204`: the model is answered with an error, and the turn goes on |
| `POST /v1/agents/{agent}/spawn` | `agent.spawn` | `agent.spawn` | starts the agent; answers it |
| `POST /v1/agents/{agent}/stop` | `agent.stop` | `agent.stop` | stops the agent, keeping its conversation, so it sleeps until something asks it; answers it |
| `POST /v1/agents/{agent}/move` | `agent.move` | `deployment.move` | starts the agent again on `{"node": ...}`, with its conversation |
| `DELETE /v1/agents/{agent}/conversation` | `agent.clear` | `agent.clear` | empties the agent's conversation, and the labels of what it held; answers its snapshot; `409` while it runs a turn or waits on a person |
| `PUT /v1/agents/{agent}/triggers/{trigger}` | `agent.trigger_set` | `agent.define` | sets or changes a trigger, and answers it; `404` where no definition is kept |
| `DELETE /v1/agents/{agent}/triggers/{trigger}` | `agent.trigger_remove` | `agent.define` | stops the trigger and deletes it, and answers it as it was |
| `POST /v1/hooks/{agent}/{trigger}` | `hook.deliver` | none | delivers a service's request to a webhook trigger, `202`; see [Webhooks](#webhooks) |
| `POST /v1/hooks/{agent}/{trigger}/{secret}` | `hook.deliver_with_secret` | none | the same, with the secret ending the path |
| `POST /v1/channels/{channel}/{path}` | `channel.deliver` | none | delivers what a chat app sends a channel; see [Channels](#channels) |
| `GET /v1/connections?owner=` | `connections.list` | `connection.read` | the accounts the owner is offered, and whether they hold each |
| `POST /v1/connections/{provider}?owner=` | `connections.connect` | `connection.connect` | where to authorize the account, or that it is held already |
| `DELETE /v1/connections/{provider}?owner=` | `connections.disconnect` | `connection.connect` | forgets the account, so the next call that needs it asks again |
| `GET /v1/servers?owner=` | `mcp_servers.list` | `mcp_server.read` | the MCP servers the owner added for their agents |
| `POST /v1/servers?owner=` | `mcp_servers.add` | `mcp_server.add` | adds an MCP server for the owner's agents, `201` |
| `DELETE /v1/servers/{server}?owner=` | `mcp_servers.remove` | `mcp_server.add` | removes the server, and answers it as it was |
| `GET /v1/secrets?owner=` | `secrets.list` | `secret.read` | the names of the owner's secrets, and whether each is sealed or an account they connected; never a value |
| `PUT /v1/secrets/{name}?owner=` | `secrets.put` | `secret.put` | seals `{"value": ...}` as the owner's secret, `204` |
| `DELETE /v1/secrets/{name}?owner=` | `secrets.delete` | `secret.put` | removes the owner's secret, `204` |
| `GET /v1/ceilings?owner=` | `ceilings.list` | `ceiling.read` | each budget the org's agents spend from together, with what they've spent |
| `POST /v1/deployment/reload` | `deployment.reload` | `deployment.reload` | reads every agent's definition again, or those `?resources=` covers |
| `GET /v1/deployment/nodes` | `deployment.nodes` | `deployment.nodes` | the deployment's nodes, each with how many agents run on it, and how many sleep |
| `GET /v1/deployment/audit` | `audit.list` | `deployment.audit` | a page of what people changed, after `?starting_after=`, up to `?limit=` |
| `GET /v1/tokens` | `tokens.list` | `deployment.tokens` | every token, oldest first, never a secret; with `?resources=`, those whose every resource the patterns cover |
| `POST /v1/tokens` | `tokens.create` | `deployment.tokens` | makes a token, `201`, with its `secret`, given this once |
| `DELETE /v1/tokens/{token}` | `tokens.revoke` | `deployment.tokens` | revokes the token, and answers it as it was |
| `GET /v1/openapi.json` | | none | the OpenAPI document |
| `GET /v1/workers` | | `agent.serve` | a WebSocket a tool worker holds open; see [Tool workers](#tool-workers) |

- `{agent}` is an agent's ID, in [its path](#agents-in-paths).
- `?resources=` is a pattern, given once for each.
- `?owner=` names an org, as `acme`, or a person, as `acme/@jon`. For `/v1/secrets`, `deployment`
  names the deployment's own secrets, which `${NAME}` in `config.yaml` reads and no agent reaches.
- The `deployment.*` actions are on the resource `deployment`, so they need an `owner` token on `*`
  or `deployment`.

Each route is an operation of `openapi.json` in `wardrik_protocol`, served at
`GET /v1/openapi.json`: what it takes and answers in OpenAPI 3.1. Its `x-wardrik-action` is the
action a route needs. [Bodies](#bodies), below, lists what each route takes and answers. The
TypeScript SDK's types are generated from the same schemas.

### Agents

```http
PUT /v1/agents/acme/triage

{"description": "Watches the incident queue.",
 "instructions": "You watch the incident queue.",
 "model": "anthropic:claude-sonnet-5",
 "tools": ["web_search"]}
```

- A definition takes the keys of an [agent file](/reference/agent-files/), with `instructions` as
  its system prompt.
- The daemon keeps it, so `GET …/definition` answers it.
- An agent brought to a new definition keeps its conversation, and takes the definition from its
  next turn.
- A key nothing here supports yet answers `501`, naming it.

### Events

```http
GET /v1/events?resources=acme/agent/*&types=wardrik.run.completed
Accept: text/event-stream

id: eyJhY21lL2FnZW50L3RyaWFnZSI6NDF9
data: {"specversion":"1.0","type":"wardrik.run.completed",…}
```

| Parameter | Means |
| --- | --- |
| `resources` | a pattern of the agents to read, given once for each; every agent the token reaches unless set |
| `types` | an event type to read, given once for each; every type unless set |
| `after` | the cursor to read after: a page's `next`, a streamed event's `id`, or a snapshot's `cursor` |
| `limit` | how many events a page holds, up to 500; 100 unless set |

- With `Accept: text/event-stream`, it streams [events](/reference/events/) as server-sent events.
  Otherwise it answers a page as JSON: `{"events": [...], "next": ...}`.
- An event's `id` is a cursor: where the reader has got to in each agent's log. An event that
  doesn't move it, such as a delta, has no `id`.
- A stream starts after `Last-Event-ID` or `?after=`, and without either at what is written next.
- A page starts after `?after=`, and at the start of each log without it.
- A `wardrik.events.dropped` comes whatever the types, where a log was trimmed past the cursor.
  Reading goes on from the oldest event the log holds.
- An idle stream sends a comment every 15 seconds.
- The server keeps no reader's place.

`GET /v1/events/head` answers `{"cursor": ...}`, the cursor at the head of every log the patterns
cover. A reader that starts from what is written next starts from it, so the cursor it keeps names
every agent it reads.

### Messages

```http
POST /v1/agents/acme/triage/messages

{"id": "msg_01", "parts": [{"type": "text", "content": "What's on fire?"}]}
```

- `content` in place of `parts` is the text alone.
- `id` is optional. A message sent again under the same `id` is taken once.
- The answer names it, with the cursor its turn is read after:
  `{"message": {"id": "msg_01", "cursor": "eyJhY21lL2FnZW50L3RyaWFnZSI6NDF9"}}`.

### Decisions

```http
POST /v1/agents/acme/triage/decisions

{"decisions": [{"id": "toolu_01", "decision": "reject", "reason": "Not this quarter."}]}
```

- Each decision names a call the agent waits on, by its `id`, and is `approve` or `reject`.
- A rejection's `reason` is what the model is told in place of the call's answer.
- An approval's `note`, as in `{"id": "toolu_01", "decision": "approve", "note": "Only this once."}`,
  is what it reads beside the answer. The call runs as the model wrote it.
- The decisions are taken together and recorded as the caller's. The answer lists each call as
  `approved` or `rejected`. `409` where the agent isn't waiting on one of them.

`POST …/interrupts/{interrupt}/approve` and `…/deny` decide one call, with `{"note": ...}` or
`{"reason": ...}`.

### Triggers

```http
PUT /v1/agents/acme/triage/triggers/sweep

{"every": "*/30 * * * *", "prompt": "Check the incident queue."}
```

A trigger takes the keys of an [agent file's triggers](/reference/agent-files/#triggers). It is part
of the agent's definition: a definition put again lists every trigger the agent has. A trigger
whose `every` and `timezone` stay keeps its next run.

### Webhooks

A service's request to `/v1/hooks/{agent}/{trigger}` carries no token. It proves itself with the
trigger's secret: as `Authorization: Bearer`, at the end of the path, or as a Standard Webhooks
signature.

| Status | Means |
| --- | --- |
| `202` | the agent was asked, or had been asked about the same request already |
| `404` | the agent has no such trigger, or the request doesn't prove itself |
| `503` | the agent can't be asked now; send it again later |

A sender learns nothing of the triggers it can't sign for. Keep a URL with the secret in its path as
private as a token.

### Channels

A chat app's request to `/v1/channels/{channel}/{path}`, such as Slack's events at
`/v1/channels/slack/events` and button presses at `.../actions`, carries no token. The daemon hands
it, as it was sent, to the channel `config.yaml` names. The channel checks it by its signature and
answers as the chat app expects. `404` where no channel of that name takes requests. See
[Slack](/channels/slack/).

### Connections

```http
GET /v1/connections?owner=acme/@jon

{"connections": [{"provider": "github", "connected": true},
                 {"provider": "linear", "connected": false}]}
```

```http
POST /v1/connections/linear?owner=acme/@jon

{"provider": "linear", "connected": false,
 "authorization": {"url": "https://linear.app/oauth/authorize?…"}}
```

- `owner` names a person, `acme/@jon`, or an org, `acme`.
- `connected` says whether the owner holds it, which is what a call of their agents would use. An
  org's account is not its people's.
- The account is held once the person has authorized it at the link. Connecting asks nobody to
  approve.
- A secret's value is never answered.

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

- An org's server serves its own agents and every agent of its people. A person's serves their
  agents alone. Its tools reach them from their next turn.
- `name` is letters, digits, `-` and `_`, up to 32, never `__`. Agents name its tools as `crm/*`,
  and the model sees each as `crm__tool`.
- It is reached over Streamable HTTP at an `https` URL whose host has public addresses.
- `only` and `except` list the server's own names of the tools to take or leave.
- Every tool the server doesn't mark `readOnlyHint` waits on a person unless a policy allows it,
  and what it answers is labelled `outside`.
- A name a server of the deployment's own that serves the owner has already is a `409`.
- Removing one forgets the sign-ins to it.

`auth` is one of:

| `auth` | Signs in |
| --- | --- |
| `{"none": {}}` | with no credential |
| `{"secret": {"name": ...}}` | with a secret the owner keeps in the vault, sent as `Authorization: Bearer` unless `header` and `scheme` say otherwise |
| `{"oauth": {"scopes": [...]}}` | in a browser, as the server's own authorization server asks; answers the link to sign in at |

### The deployment

```http
GET /v1/deployment/nodes

{"nodes": [{"name": "wardrik@box1", "agents": 12}], "asleep": 40}
```

```http
GET /v1/deployment/audit?starting_after=120&limit=50

{"events": [{"type": "wardrik.agent.defined", "subject": "agents/acme/triage", …}], "next": 170}
```

A change in the audit is a CloudEvent, as an agent's events are. Its `data.actor` is who made it,
and `data.assumed_by`, where anyone acted for them, who did, first to last.

`POST /v1/deployment/reload` answers the nodes that read the definitions again, as `reloaded`,
and what the agent files couldn't read or define, as `problems`.

### Tool workers

A tool worker is an MCP server that dials in. It opens a WebSocket to `GET /v1/workers` with a
token that holds `agent.serve`, as the `worker` role does. Messages are JSON-RPC 2.0, one per text
frame, as MCP `2025-06-18` specifies:

1. Wardrik sends `initialize`, then `notifications/initialized` once the worker answers.
2. Wardrik sends `tools/list`. The worker sends `notifications/tools/list_changed` to be listed
   again.
3. Wardrik sends `tools/call` for each call an agent makes, and the worker answers with a
   `CallToolResult`.
4. Wardrik sends `notifications/cancelled` when it stops waiting on a call.

- An agent whose tools include `workers/*` is offered the tools of every worker whose token may
  `agent.serve` it. The model sees each as `workers__NAME`.
- A call's `_meta` holds the `agent` it is for, its `run`, the `principal` it acts for, and an
  `idempotencyKey` that stays the same if the call is retried.
- A worker that answers with `_meta.costUsd` says what the call cost in US dollars, which a budget
  counts.
- A request with a working token that isn't a WebSocket upgrade answers `426`, so a worker can
  check its token first.
- The socket closes with `1008` once the token stops working.

See [Tools in your app](/build/tool-workers/).

## Every response

- Carries a `request-id` header, the caller's own where it sent one.
- An error is `{"error": {"type": …, "message": …}}`, with the status for its type:

| `type` | Status |
| --- | --- |
| `invalid_request` | `400` |
| `unauthorized` | `401` |
| `forbidden` | `403` |
| `not_found` | `404` |
| `conflict` | `409` |
| `internal` | `500` |
| `not_supported` | `501` |
| `unavailable` | `503` |

- A body over 8 MB is refused.
- A request that changes something is recorded in the audit with the caller.

## Bodies

The JSON the routes take and answer with.

### `agent`

One agent of agents.list.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | yes | The agent's ID: org/name, or org/@user/name for one that works for a user. |
| `name` | string | yes |  |
| `status` | string | yes | Whether it waits for a message, answers one, waits on a person, or sleeps until something asks it. One of `idle`, `running`, `parked`, `asleep`. |
| `pending` | integer | yes | How many messages wait behind what it's doing. |
| `node` | string or null |  | The node it runs on, by its name; null while it sleeps. |
| `next_run` | string or null |  | When the next of its triggers on a clock runs; null where none does. |
| `spent_today` | [spent](/reference/events/#spent) |  |  |

### `agent_answer`

What agent.spawn and agent.stop answer: the agent, as agents.list lists it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | [agent](/reference/http-api/#agent) | yes |  |

### `agent_definition`

What agent.define takes, and agent.definition answers: what an agent is, and what it may do. An agent file's frontmatter takes the same keys, with its body as instructions, and name, org and user besides.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `display_name` | string |  | What a person calls the agent; its name unless given. |
| `description` | string |  | What the agent is for, in words a person reads. |
| `instructions` | string |  | The system prompt. |
| `model` | string |  | The model, as provider:model. |
| `tools` | array of string |  | What the agent may call: a tool the server ships, by name; files for the file tools over the agent's own tree and the trees it shares; server/* for every tool of an MCP server; workers/* for every tool the connected tool workers offer it; self/* for its operations on itself; agents/* for its operations on the agents of its org; or * for all of them. |
| `workspace` | object |  | The trees the agent shares with other agents. Only trees the token's scope covers, and tools names files to reach them. |
| `workspace.shared` | object |  | The trees shared with the agent, by the name each is seen under at shared/<name>/: a tree, or a tree and a mode, write unless it says read. |
| `context` | array of string or object |  | The files read into each turn, at most 20, in the agent's tree or one it shares, up to 16 KB of them unless max_bytes says. tools names files to read them with. |
| `context.files` | array of string |  |  |
| `context.max_bytes` | integer |  |  |
| `policy` | string or object |  |  |
| `timeout` | integer |  | How many seconds a turn may take. |
| `idle_timeout` | integer or `"infinity"` |  | How many seconds the agent may have nothing to do before it sleeps, until something asks it. The server's default when absent. |
| `max_iterations` | integer or `"infinity"` |  | How many rounds of tool calls a turn may make. |
| `retries` | object |  | How a turn tries a failed model call again, after a random wait of up to a second that doubles each time. A 4xx answer other than 408, 425 and 429 is not tried again. The host's defaults hold where this is absent. |
| `retries.attempts` | integer |  | How many times a failed model call is tried again: 6 unless set. 0 never tries again. |
| `retries.max_wait` | integer |  | The longest wait between tries, in seconds: 60 unless set. |
| `retries.on_exhausted` | string |  | What happens once the tries are spent: ask a person whether to try again, or fail the turn. ask unless set. One of `ask`, `fail`. |
| `compaction` | `false` or object |  | When the agent summarises its older history, as shares of the model's window; false never does. |
| `compaction.at` | number |  |  |
| `compaction.keep` | number |  |  |
| `compaction.window` | integer |  |  |
| `triggers` | array of object |  | The triggers that ask the agent something when they come round, each with a prompt or a prompt_file. A definition put again replaces them all, and PUT and DELETE /v1/agents/{agent}/triggers/{trigger} change one. Any other field is the source's that the trigger watches, which one of them names; without one, it asks on every run. A trigger on a clock has every, and a timezone a cron expression is read in; a webhook has webhook in its place, holding its secret and how a request is verified, and is sent requests at POST /v1/hooks/{agent}/{trigger}. |
| `triggers[].name` | string |  | The trigger's name, trigger-1, trigger-2 and so on by its place in the list where it is left out. |
| `triggers[].every` | string |  | A cron expression, or a duration such as 30m. |
| `triggers[].timezone` | string |  | The time zone a cron expression in every is read in, by its IANA name, as Europe/Berlin; Etc/UTC where it is left out. A duration counts elapsed time and takes none. |
| `triggers[].prompt` | string |  | What the agent is asked each time. |
| `triggers[].prompt_file` | string |  | In place of prompt, a file in the agent's tree: each time, the agent is asked to read it and do what it says. tools names files to read it with. |
| `triggers[].overlap` | string |  | What a firing does while a run is still going: skip it, or queue its prompt. One of `skip`, `queue`. |
| `triggers[].missed` | string |  | What a trigger does about the firings it missed while down. One of `run_once`, `skip`. |
| `triggers[].jitter` | integer |  | Up to this many seconds of delay, chosen at random each time. |
| `triggers[].feed` | string or array of string |  | An RSS or Atom feed's URL, or a list of them: the agent is asked only when one has new entries, with them under the prompt. The first run only notes what a feed holds. |
| `triggers[].webhook` | object |  | In place of every: a service sends the trigger requests, each asked about once. |
| `triggers[].webhook.secret` | string | yes | The secret the service holds, as ${NAME}. |
| `triggers[].webhook.verify` | string |  | shared, where a request presents the secret as a bearer token or at the end of its path, or standard, where it is signed as Standard Webhooks says; shared unless set. One of `shared`, `standard`. |
| `notify` | string or array of string or object |  | Who hears when the agent parks, fails or answers: a target config.yaml's notify names or a room in a channel, as slack:#updates; a list of them; or to and on. A target tells only the agents of the orgs it serves, and a room is posted in a workspace of the agent's own owner. |
| `notify.to` | string or array of string | yes | The targets, as config.yaml's notify names them, and rooms in channels, as slack:#updates. |
| `notify.on` | array of string |  | What is sent: parked and failed turns unless set, and finished for what a turn answered. |
| `channels` | array of string |  | The chat channels, as config.yaml names them, it may be chosen to answer in. |

### `agent_snapshot`

What agent.read answers: what the agent is doing now, and where its log stands. Read and follow the log after cursor.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID: org/name, or org/@user/name for one that works for a user. |
| `agent.name` | string | yes |  |
| `status` | string | yes | Whether it waits for a message, answers one, waits on a person, or sleeps until something asks it. One of `idle`, `running`, `parked`, `asleep`. |
| `node` | string or null |  | The node it runs on, by its name; null while it sleeps. |
| `pending` | integer | yes |  |
| `activity` | [activity](/reference/events/#activity) | yes |  |
| `interrupts` | array of [interrupt](/reference/events/#interrupt) | yes | The calls it waits on a person for. |
| `cursor` | string | yes | Where its log stands, as events.list and agent.events take it. |
| `next_run` | string or null |  | When the next of its triggers on a clock runs; null where none does. |
| `spent_today` | [spent](/reference/events/#spent) |  |  |

### `agents`

What agents.list answers: the agents the patterns cover.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agents` | array of [agent](/reference/http-api/#agent) | yes |  |

### `approve`

What agent.approve takes: a note the agent reads beside the call's answer, if any. The call runs as the model wrote it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `note` | string |  |  |

### `ask`

What agent.ask takes: its text as content, or as text parts, under an id of the caller's, or one it's given. A message sent again under the same id is taken once.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string |  |  |
| `content` | string |  |  |
| `parts` | array of [part](/reference/events/#part) |  |  |

### `asked`

What agent.ask answers: the message by its id, with the cursor where the agent's log stood. The turn that answers it is written after it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | object | yes |  |
| `message.id` | string | yes |  |
| `message.cursor` | string | yes |  |

### `audit`

What audit.list answers: what people changed across the deployment, oldest first.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `events` | array of [event](/reference/events/#the-envelope) | yes |  |
| `next` | integer | yes | The sequence after these changes, to read on from. |

### `authorization`

Where a person authorizes the call an interrupt with reason authorization waits on: what agent.authorization answers, to a token that may decide the agent's calls. The link is in no event.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `url` | string | yes | The page to open. |
| `code` | string |  | The code to enter at the page, where one is needed. |

### `calls`

What agent.calls answers: the tool calls an agent is running now, each with how long it has run.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `calls` | array of object | yes |  |
| `calls[].id` | string | yes | The call's id. |
| `calls[].name` | string | yes | The tool it calls. |
| `calls[].elapsed_ms` | integer | yes | How long it has run, in milliseconds. |

### `cancelled`

What agents.cancel answers: the IDs of the agents whose turn it ended.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `cancelled` | array of string | yes |  |

### `ceilings`

What ceilings.list answers: each of an org's ceilings, budgets its agents spend from together, with what they've spent against it in its period now.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `ceilings` | array of object | yes |  |
| `ceilings[].ceiling` | string | yes | The ceiling's name. |
| `ceilings[].per` | string | yes | How long its limit lasts before it starts over. One of `day`, `week`, `month`, `total`. |
| `ceilings[].on_exhausted` | string | yes | What the org's next model call does once they've spent it: waits on a ceiling_approval, is refused, or runs. One of `ask`, `deny`, `continue`. |
| `ceilings[].limit` | [amount](/reference/events/#amount) | yes |  |
| `ceilings[].spent` | [amount](/reference/events/#amount) | yes |  |
| `ceilings[].granted` | [amount](/reference/events/#amount) | yes |  |
| `ceilings[].starts_over` | string (date) |  | The day it starts over, in its timezone. Absent for a ceiling in total. |

### `channel_request`

What channel.deliver takes: the request a chat app sent, its raw body and its headers, with lowercase names. The surface that receives it passes them on as they came, since a signature covers the exact body.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `body` | string | yes | The request's body, as it was sent. |
| `headers` | object | yes | The request's headers, by lowercase name. |

### `channel_response`

What channel.deliver answers: the response the chat app expects, which a surface sends as it is, in place of JSON of its own.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `status` | integer | yes |  |
| `headers` | object | yes | The response's headers, by lowercase name. |
| `body` | string | yes |  |

### `connecting`

What connections.connect answers: that the owner holds the account already, or where to authorize it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `provider` | string | yes | The account's name, as the deployment configures it. |
| `connected` | boolean | yes | Whether the owner holds it already. |
| `authorization` | [authorization](/reference/http-api/#authorization) |  | Where to authorize it, where it is not held yet. |

### `connection`

An account an owner is offered, by the provider's name, and whether they hold it. A value is never answered.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `provider` | string | yes | The account's name, as the deployment configures it. |
| `connected` | boolean | yes | Whether the owner holds it, which is what a call of an agent they own would use. |

### `connections`

What connections.list answers: the accounts an owner is offered, and whether they hold each. A value is never answered.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `connections` | array of [connection](/reference/http-api/#connection) | yes |  |

### `cursor`

What events.head answers: the cursor at the end of every log the patterns cover.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `cursor` | string | yes |  |

### `decided`

What agent.decide answers: each call by its id, approved or rejected.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `decisions` | array of object | yes |  |
| `decisions[].id` | string | yes |  |
| `decisions[].decision` | string | yes | One of `approved`, `rejected`. |

### `decisions`

What agent.decide takes: what a person decides of the calls an agent waits on, taken together.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `decisions` | array of object | yes |  |
| `decisions[].id` | string | yes | The id of a call the agent waits on, an interrupt's. |
| `decisions[].decision` | string | yes | One of `approve`, `reject`. |
| `decisions[].note` | string |  | For an approval, what the agent is told with it. |
| `decisions[].reason` | string |  | For a rejection, why, which the agent is told. |

### `definition_read`

What agent.definition answers: the definition last put, as it was sent, and the tools it names that offer nothing yet.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `definition` | [agent_definition](/reference/http-api/#agent_definition) | yes |  |
| `missing` | array of string | yes | The tools the definition names that offer nothing yet, such as server/* for an MCP server its owner has not added. Each offers its tools once what it names is there, without the definition being put again. |
| `next_runs` | object |  | When each of its triggers runs next, by name; null for one a webhook asks. |

### `deny`

What agent.deny takes: why, which the agent is told in place of the call's answer.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `reason` | string |  |  |

### `error`

What an operation answers when it fails, and what every HTTP answer of 400 and above holds.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `error` | object | yes |  |
| `error.type` | string | yes | One of `invalid_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `not_supported`, `unavailable`, `internal`. |
| `error.message` | string | yes |  |

### `events`

What events.list and agent.events answer: the events after the cursor, oldest first.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `events` | array of [event](/reference/events/#the-envelope) | yes | Each event's source names its agent, and its sequence its place in that agent's log. Where a log was trimmed past the cursor, a wardrik.events.dropped says so. |
| `next` | string | yes | The cursor after these events, to read on from. |

### `forgotten`

What agents.forget answers: the IDs it forgot, those kept with why, and those it couldn't forget with why.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `forgotten` | array of string | yes |  |
| `kept` | array of object | yes |  |
| `kept[].id` | string | yes |  |
| `kept[].why` | string | yes |  |
| `failed` | array of object | yes |  |
| `failed[].id` | string | yes |  |
| `failed[].why` | string | yes |  |

### `hook_request`

What hook.deliver takes: the request a service sent, its raw body and its headers, with lowercase names. The surface that receives it passes them on as they came, since a signature covers the exact body.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `body` | string | yes | The request's body, as it was sent. |
| `headers` | object | yes | The request's headers, by lowercase name. |

### `interrupts`

What interrupts.list answers: the calls agents wait on a person for, each with its agent.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `interrupts` | array of object | yes |  |
| `interrupts[].agent` | object | yes |  |
| `interrupts[].agent.id` | string | yes | The agent's ID: org/name, or org/@user/name for one that works for a user. |
| `interrupts[].interrupt` | [interrupt](/reference/events/#interrupt) | yes |  |

### `node`

What agent.move takes: the node to start the agent again on, by its name.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `node` | string | yes | A node's name, as wardrik@box1. |

### `nodes`

What deployment.nodes answers: the deployment's nodes, each with how many agents run on it, and how many sleep on none.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `nodes` | array of object | yes |  |
| `nodes[].name` | string | yes | The node's name, as an agent's node is given. |
| `nodes[].agents` | integer | yes | How many agents run on it. |
| `asleep` | integer | yes | How many agents sleep, on no node, until something asks them. |

### `reloaded`

What deployment.reload answers: the nodes that read every agent's definition again, and what the declarations couldn't read or define.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `reloaded` | array of string | yes |  |
| `problems` | array of string |  | What the deployment's declarations, as agent files, couldn't read or define, a line each. None unless set. |

### `runs`

What agent.runs answers: each run, newest first, and the totals across them.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `runs` | array of object | yes |  |
| `runs[].id` | string | yes |  |
| `runs[].status` | string | yes | One of `running`, `completed`, `failed`, `cancelled`, `waiting`. |
| `runs[].started_at` | string | yes |  |
| `runs[].finished_at` | string or null |  |  |
| `runs[].duration_ms` | integer or null |  |  |
| `runs[].source` | string or null |  | Who sent the message it answered. |
| `runs[].model` | string or null |  |  |
| `runs[].tool_calls` | integer | yes |  |
| `runs[].tool_errors` | integer | yes |  |
| `runs[].input_tokens` | integer | yes |  |
| `runs[].output_tokens` | integer | yes |  |
| `runs[].cost_micro_usd` | integer | yes |  |
| `runs[].error` | string or null |  |  |
| `totals` | object | yes |  |
| `totals.runs` | integer | yes |  |
| `totals.failed` | integer | yes |  |
| `totals.tool_calls` | integer | yes |  |
| `totals.input_tokens` | integer | yes |  |
| `totals.output_tokens` | integer | yes |  |
| `totals.cost_micro_usd` | integer | yes |  |
| `totals.last_at` | string or null | yes |  |
| `cursor` | string | yes |  |

### `secret_input`

What secrets.put takes: the value to seal.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `value` | string | yes |  |

### `secrets`

What secrets.list answers: each secret the owner holds, by name, and whether it's one they sealed or an account they connected. Never a value.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `secrets` | array of object | yes |  |
| `secrets[].name` | string | yes |  |
| `secrets[].kind` | string | yes | secret for one the owner sealed, grant for an account they connected. One of `secret`, `grant`. |

### `server`

An MCP server an owner added for their agents: its name, its URL, and how its agents sign in to it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes | What the owner's agents call it. |
| `url` | string | yes | The server's URL. |
| `auth` | any | yes | How its agents sign in to it. One of `oauth`, `secret`, `none`. |

### `server_added`

What mcp_servers.add answers: that the owner's agents can call the server now, or where someone signs in to it first.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `server` | string | yes | The server's name. |
| `connected` | boolean | yes | Whether its agents can call it now. |
| `authorization` | [authorization](/reference/http-api/#authorization) |  | Where to sign in to it, where someone has to first. |

### `server_input`

What mcp_servers.add takes: the server's name, its URL, how the owner's agents sign in to it, and which of its tools they take.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes | What the owner's agents call it: their definitions name its tools as name/*, and each tool arrives as name__tool. Letters, digits, - and _, up to 32, never __. |
| `url` | string | yes | The server's whole URL, over https, reached as Streamable HTTP. |
| `auth` | object, one of the shapes below | yes | How the owner's agents sign in to it. |
| `auth.none` | object | yes | It takes no credential. |
| `auth.oauth` | object | yes | The owner signs in in a browser, and the token is kept for them. Left bare, the server's own authorization server is found from its URL, and Wardrik becomes its client itself. Where it can't be, as with a service that publishes no metadata or registers no clients, the owner gives the OAuth app they registered there: its issuer or its endpoints, its client_id, and the name of the secret they keep its client secret under. |
| `auth.oauth.scopes` | array of string |  | The scopes to ask for, the server's own unless it says. |
| `auth.oauth.issuer` | string |  | The authorization server's issuer URL, whose metadata names its endpoints. |
| `auth.oauth.authorization_endpoint` | string |  | Where a person signs in, where the issuer publishes no metadata. Given with token_endpoint. |
| `auth.oauth.token_endpoint` | string |  | Where a code is exchanged for a token. Given with authorization_endpoint. |
| `auth.oauth.client_id` | string |  | The owner's OAuth app's client ID. |
| `auth.oauth.client_secret` | object |  | The app's client secret, as a secret the owner keeps in the vault. It is sealed apart from the owner's secrets as the server is added, so it is never sent anywhere but the token endpoint. |
| `auth.oauth.client_secret.name` | string | yes | The secret's name in the owner's vault. |
| `auth.oauth.client_auth` | string |  | How the client secret is sent: in the form, or as HTTP Basic. post unless it says. One of `post`, `basic`. |
| `auth.secret` | object | yes | A key the owner keeps in the vault, sent with every call. |
| `auth.secret.name` | string | yes | The secret's name in the owner's vault. |
| `auth.secret.header` | string |  | The header it is sent in; authorization unless it says. |
| `auth.secret.scheme` | string |  | What comes before it in the header; Bearer unless it says, and nothing where it is empty. |
| `only` | array of string |  | The server's own names of the tools to take, every one unless it says. |
| `except` | array of string |  | The server's own names of the tools to leave. |

### `servers`

What mcp_servers.list answers: the MCP servers an owner added for their agents.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `servers` | array of [server](/reference/http-api/#server) | yes |  |

### `timeline`

What agent.timeline answers: the agent's conversation as a person reads it, oldest first.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `items` | array of objects, each one of the shapes below | yes |  |
| `items[].id` | string | yes |  |
| `items[].kind` | `"user"` | yes |  |
| `items[].text` | string | yes | Where kind is user. |
| `items[].sender` | string or null |  | Where kind is user. |
| `items[].at` | string or null |  | Where kind is user. |
| `items[].kind` | `"run"` | yes |  |
| `items[].status` | string | yes | Where kind is run. One of `running`, `completed`, `failed`, `cancelled`, `waiting`. |
| `items[].steps` | array of objects, each one of the shapes below | yes | Where kind is run. |
| `items[].steps[].id` | string | yes | Where kind is run. |
| `items[].steps[].type` | string | yes | Where kind is run. One of `thinking`, `text`. |
| `items[].steps[].text` | string | yes | Where kind is run. |
| `items[].steps[].live` | boolean | yes | Where kind is run. Whether it's still streaming. |
| `items[].steps[].type` | `"tool"` | yes | Where kind is run. |
| `items[].steps[].name` | string | yes | Where kind is run. Where type is tool. |
| `items[].steps[].arguments` | any |  | Where kind is run. Where type is tool. |
| `items[].steps[].status` | string | yes | Where kind is run. Where type is tool. One of `running`, `ok`, `error`, `denied`. |
| `items[].steps[].result` | any |  | Where kind is run. Where type is tool. |
| `items[].steps[].error` | string or null |  | Where kind is run. Where type is tool. |
| `items[].model` | string or null |  | Where kind is run. |
| `items[].cost_micro_usd` | integer |  | Where kind is run. |
| `items[].started_at` | string or null |  | Where kind is run. |
| `items[].finished_at` | string or null |  | Where kind is run. |
| `items[].error` | string or null |  | Where kind is run. |
| `items[].interrupts` | array of [interrupt](/reference/events/#interrupt) |  | Where kind is run. |
| `cursor` | string | yes | Where the log stood, to follow it from. |

### `token`

An API token as Wardrik keeps it, never its secret.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | yes | What revoking it takes. |
| `name` | string | yes |  |
| `principal` | [principal](/reference/events/#principal) | yes | Whom it acts for: whoever made it. |
| `statements` | array of [statement](/reference/events/#statement) | yes | What it allows, on what; anything none states is denied. |
| `policy` | string |  | The policy every agent it defines runs under, ahead of the agent's own, by its name: what IAM calls a permissions boundary. Absent where it names none. |
| `expires` | string (date-time) |  | When it stops working. |
| `created_at` | string (date-time) | yes |  |

### `token_input`

What tokens.create takes: its name, the resources it reaches, and the roles it holds there. It acts for whoever makes it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes | What it is listed as. |
| `resources` | array of string | yes | What it reaches, each a resource pattern: acme/agent/* for acme's own agents, acme/@jon/* for everything of a user's, acme/* for everything of the org's and its users', acme/agent/triage for one agent, or * for everything. |
| `roles` | array of string | yes | What it may do there, each a named set of actions. |
| `policy` | string |  | The policy every agent it defines runs under, ahead of the agent's own, by the name the server holds it under: what IAM calls a permissions boundary. The token making it names its own where this is left out. |
| `expires_in` | integer |  | How many seconds it works for; the server's own lifetime for API tokens, 90 days unless set, where left out. |

### `token_issued`

What tokens.create answers: the token just made, and the secret that presents it, given this once.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `token` | [token](/reference/http-api/#token) | yes |  |
| `secret` | string | yes | What a request presents, as Authorization: Bearer secret. |

### `tokens`

What tokens.list answers: every API token, oldest first.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `tokens` | array of [token](/reference/http-api/#token) | yes |  |

### `trigger_definition`

What agent.trigger_set takes, with a prompt or a prompt_file, and what it and agent.trigger_remove answer, with its name. A trigger on a clock has every, and a cron expression a timezone where it is not UTC; overlap is skip, missed is run_once and jitter is 0 where they are left out. feed watches an RSS or Atom feed, or a list of them. A webhook has webhook in place of every, holding its secret, as ${NAME}, and verify, shared or standard; it is sent requests at POST /v1/hooks/{agent}/{trigger}, and its overlap is queue where it says none.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string |  | The trigger's name, which the path gives. |
| `every` | string |  | A cron expression, or a duration such as 30m. |
| `timezone` | string |  | The time zone a cron expression in every is read in, by its IANA name, as Europe/Berlin; Etc/UTC where it is left out. A duration counts elapsed time and takes none. |
| `prompt` | string |  | What the agent is asked each time. |
| `prompt_file` | string |  | In place of prompt, a file in the agent's tree: each time, the agent is asked to read it and do what it says. tools names files to read it with. |
| `overlap` | string |  | What a firing does while a run is still going: skip it, or queue its prompt. One of `skip`, `queue`. |
| `missed` | string |  | What a trigger does about the firings it missed while down. One of `run_once`, `skip`. |
| `jitter` | integer |  | Up to this many seconds of delay, chosen at random each time. |
| `feed` | string or array of string |  | An RSS or Atom feed's URL, or a list of them: the agent is asked only when one has new entries, with them under the prompt. The first run only notes what a feed holds. |
| `webhook` | object |  | In place of every: a service sends the trigger requests, each asked about once. |
| `webhook.secret` | string | yes | The secret the service holds, as ${NAME}. |
| `webhook.verify` | string |  | shared, where a request presents the secret as a bearer token or at the end of its path, or standard, where it is signed as Standard Webhooks says; shared unless set. One of `shared`, `standard`. |
