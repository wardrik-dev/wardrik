---
title: "HTTP API"
description: "Every route the wardrik daemon serves, with its fields, a request and a response."
sidebar:
  order: 5
---

```sh
export WARDRIK_URL=http://127.0.0.1:4747
curl $WARDRIK_URL/v1/agents -H "Authorization: Bearer $WARDRIK_TOKEN"
```

- The daemon listens on `127.0.0.1:4747`. [`http`](/reference/config/#http) in `config.yaml` moves it.
- Every request sends `Authorization: Bearer <token>`. Make one with [`wardrik token create`](/reference/cli/#tokens).
  Webhooks and chat apps send none.
- Bodies are JSON, up to 8 MB. Webhooks and chat apps send their own bodies, as they are.
- Every response has a `request-id` header. It's yours if you sent one.
- `GET /v1/openapi.json` returns the OpenAPI 3.1 document for the library's routes.
  The daemon's own routes (`/v1/owners/...`, `/v1/connections`, `/v1/tokens`) are in `wardrik_daemon`'s
  `priv/openapi.json`.
- See [Use the HTTP API](/build/http-api/) for a walk-through.

## Errors

```json
{"error": {"type": "not_found", "message": "No agent runs under agt_01JF8X5RQ2."}}
```

| `type` | Status | When |
| --- | --- | --- |
| `invalid_request` | `400` | the input doesn't read |
| `unauthorized` | `401` | no token, or one unknown or expired |
| `forbidden` | `403` | the token may not do this |
| `not_found` | `404` | no such thing, or one the token can't reach |
| `conflict` | `409` | it conflicts with what's there, like a call the agent doesn't wait on |
| `internal` | `500` | a bug |
| `not_supported` | `501` | not supported yet |
| `unavailable` | `503` | can't be done now; try again later |

## IDs in paths

- `{agent}` is an agent ID, as the daemon minted it: `agt_01JF8X5RQ2`. URL-encode it as one segment.
- `{owner}` is one URL-encoded segment: `acme` (an org), `acme%2F%40jon` (a person), or `deployment`.
- `?agents=` lists agent IDs, one per `agents=`. Left out, it means every agent the token reaches.

### Conversations

An agent can hold many conversations. Put `/conversations/{conversation}` after the agent to act on one:

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/conversations/C1/messages \
  -H "Authorization: Bearer $WARDRIK_TOKEN" --json '{"content": "Hi"}'
```

These routes take the conversation form: read, clear (`DELETE .../conversations/{conversation}`),
messages, decisions, approve, deny, authorization, cancel, stop, events, timeline, runs, calls, stop a
call, and move.

- Clearing a conversation empties its history. The conversation's ID still takes messages.
- In `openapi.json`, a conversation route has no `operationId`. Its `x-wardrik-operation` names the
  operation it serves, such as `agent.ask`.

## Agents

### List agents

`GET /v1/agents`

Lists the agents the token reaches.

| Parameter | Type | Description |
| --- | --- | --- |
| `agents` | string, repeated | agent IDs to list |

```sh
curl $WARDRIK_URL/v1/agents -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"agents": [{"id": "agt_01JF8X5RQ2", "status": "parked", "pending": 0, "node": "wardrik@box1"}]}
```

Each agent has `id`, `conversation`, `status`, `pending`, `node`, `next_run` and `spent_today`, as
[Read an agent](#read-an-agent) describes them.

### Read an agent

`GET /v1/agents/{agent}`

Returns what the agent is doing now.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2 -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{
  "agent": {"id": "agt_01JF8X5RQ2"},
  "status": "parked",
  "pending": 0,
  "activity": {
    "doing": [{"type": "wardrik.run.interrupted",
               "interrupts": [{"id": "toolu_01", "reason": "tool_approval", "message": "Open an issue?", "tool_call_id": "toolu_01"}]}],
    "since": "2026-10-22T09:00:00.000000Z",
    "pending": 0
  },
  "interrupts": [{"id": "toolu_01", "reason": "tool_approval", "message": "Open an issue?", "tool_call_id": "toolu_01"}],
  "cursor": "W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ"
}
```

| Field | Type | Description |
| --- | --- | --- |
| `status` | string | `idle`, `running`, `parked` (waits on a person) or `asleep` |
| `node` | string or null | the node it runs on; `null` while asleep |
| `pending` | integer | messages queued behind the current one |
| `activity` | object | what it's doing, as [`activity`](/reference/events/#shared-types) |
| `interrupts` | array | calls it waits on a person for |
| `cursor` | string | where its event log stands; pass it as `after` |
| `next_run` | string or null | when its next clock trigger runs |
| `spent_today` | object | what it spent today |

### Define an agent

`PUT /v1/agents/{agent}`

Starts the agent the definition describes, or updates the running one from its next turn.

The body is an [agent definition](/reference/agent-files/#keys). The daemon only takes IDs it minted, so
make the agent with [`POST /v1/owners/{owner}/agents`](#make-an-agent) first.

```sh
curl -X PUT $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2 -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"instructions": "You watch the incident queue.", "model": "anthropic:claude-sonnet-5", "tools": ["web_search"]}'
```

Returns the agent, as [Read an agent](#read-an-agent) does. An unsupported key returns `501`.

### Read a definition

`GET /v1/agents/{agent}/definition`

Returns the definition last put, and the tools it names that offer nothing yet.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/definition -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"definition": {"instructions": "Answer customers' questions about their orders.", "tools": ["crm/*"]},
 "missing": ["crm/*"]}
```

| Field | Type | Description |
| --- | --- | --- |
| `definition` | object | the definition, as sent |
| `missing` | array | tools named that aren't there yet, like an MCP server not added |
| `next_runs` | object | when each trigger runs next, by name; `null` for a webhook |

### Start an agent

`POST /v1/agents/{agent}/spawn`

Starts the agent.

```sh
curl -X POST $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/spawn -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"agent": {"id": "agt_01JF8X5RQ2", "status": "idle", "pending": 0}}
```

### Stop an agent

`POST /v1/agents/{agent}/stop`

Puts the agent to sleep, keeping its conversation, until something asks it.

```sh
curl -X POST $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/stop -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"agent": {"id": "agt_01JF8X5RQ2", "status": "asleep", "pending": 0}}
```

### Clear an agent's history

`DELETE /v1/agents/{agent}/conversation`

Empties the agent's history. The agent, its definition and its other conversations stay. Returns
`409` while it runs a turn or waits on a person.

```sh
curl -X DELETE $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/conversation -H "Authorization: Bearer $WARDRIK_TOKEN"
```

Returns the agent, as [Read an agent](#read-an-agent) does.

### Forget an agent

`DELETE /v1/agents/{agent}`

Stops the agent and deletes its conversation, definition and triggers. Returns `204`.

```sh
curl -X DELETE $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2 -H "Authorization: Bearer $WARDRIK_TOKEN"
```

### Forget many agents

`DELETE /v1/agents`

Forgets each agent `?agents=` names, or every agent the token reaches.

| Parameter | Type | Description |
| --- | --- | --- |
| `agents` | string, repeated | agent IDs to forget |

```sh
curl -X DELETE "$WARDRIK_URL/v1/agents?agents=agt_01JF8X5RQ2" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"forgotten": ["agt_01JF8X5RQ2"], "kept": [], "failed": []}
```

`kept` and `failed` entries are `{"id": ..., "why": ...}`. An agent an agent file declares is kept.

### Move an agent

`POST /v1/agents/{agent}/move`

Restarts the agent on another node. A turn in progress ends; ask it again once it's moved.

| Field | Type | Description |
| --- | --- | --- |
| `node` | string, required | the node's name |

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/move -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"node": "wardrik@box2"}'
```

```json
{"agent": {"id": "agt_01JF8X5RQ2", "status": "idle", "pending": 0, "node": "wardrik@box2"}}
```

## Messages

### Send a message

`POST /v1/agents/{agent}/messages`

Queues a message for the agent. Returns `202`.

| Field | Type | Description |
| --- | --- | --- |
| `content` | string | the text |
| `parts` | array | the text as parts, in place of `content` |
| `id` | string | your ID for it; a message sent again with the same `id` is taken once |

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/messages -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"id": "msg_01", "content": "What is on fire?"}'
```

```json
{"message": {"id": "msg_01", "cursor": "W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ"}}
```

Read the reply from the [events](#read-events) after `cursor`.

### Cancel a turn

`POST /v1/agents/{agent}/cancel`

Ends the current turn and drops queued messages. The agent keeps running. Returns `202`.

```sh
curl -X POST $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/cancel -H "Authorization: Bearer $WARDRIK_TOKEN"
```

### Cancel many agents

`POST /v1/agents/cancel`

Ends the current turn of each agent `?agents=` names, or every agent the token reaches. Returns `202`.

```sh
curl -X POST "$WARDRIK_URL/v1/agents/cancel?agents=agt_01JF8X5RQ2" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"cancelled": ["agt_01JF8X5RQ2"]}
```

### List running tool calls

`GET /v1/agents/{agent}/calls`

Lists the tool calls the agent is running. Returns `404` while it sleeps.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/calls -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"calls": [{"id": "toolu_01", "name": "github__search_issues", "elapsed_ms": 1250}]}
```

### Stop a tool call

`DELETE /v1/agents/{agent}/calls/{call}`

Stops one tool call. The model gets an error and the turn goes on. Returns `204`.

```sh
curl -X DELETE $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/calls/toolu_01 -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Approvals

### List waiting calls

`GET /v1/interrupts`

Lists the calls agents wait on a person for.

| Parameter | Type | Description |
| --- | --- | --- |
| `agents` | string, repeated | agent IDs to cover |

```sh
curl $WARDRIK_URL/v1/interrupts -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"interrupts": [{"agent": {"id": "agt_01JF8X5RQ2"},
                 "interrupt": {"id": "toolu_01", "reason": "tool_approval", "message": "Open an issue?", "tool_call_id": "toolu_01"}}]}
```

An entry has `conversation` when the call is in one.

### Approve a call

`POST /v1/agents/{agent}/interrupts/{interrupt}/approve`

Approves one call. It runs as the model wrote it.

| Field | Type | Description |
| --- | --- | --- |
| `note` | string | what the agent reads beside the call's answer |

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/interrupts/toolu_01/approve \
  -H "Authorization: Bearer $WARDRIK_TOKEN" --json '{"note": "Only staging."}'
```

```json
{"decisions": [{"id": "toolu_01", "decision": "approved"}]}
```

### Deny a call

`POST /v1/agents/{agent}/interrupts/{interrupt}/deny`

Rejects one call.

| Field | Type | Description |
| --- | --- | --- |
| `reason` | string | what the model is told in place of the call's answer |

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/interrupts/toolu_01/deny \
  -H "Authorization: Bearer $WARDRIK_TOKEN" --json '{"reason": "Not this quarter."}'
```

```json
{"decisions": [{"id": "toolu_01", "decision": "rejected"}]}
```

### Decide many calls

`POST /v1/agents/{agent}/decisions`

Approves or rejects several waiting calls together.

| Field | Type | Description |
| --- | --- | --- |
| `decisions[].id` | string, required | the waiting call's ID |
| `decisions[].decision` | string, required | `approve` or `reject` |
| `decisions[].note` | string | for an approval |
| `decisions[].reason` | string | for a rejection |

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/decisions -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"decisions": [{"id": "toolu_01", "decision": "reject", "reason": "Not this quarter."},
                         {"id": "toolu_02", "decision": "approve"}]}'
```

```json
{"decisions": [{"id": "toolu_01", "decision": "rejected"}, {"id": "toolu_02", "decision": "approved"}]}
```

### Read a sign-in link

`GET /v1/agents/{agent}/interrupts/{interrupt}/authorization`

Returns where a person signs in, for a call waiting with reason `authorization`.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/interrupts/toolu_01/authorization \
  -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"url": "https://github.com/login/device", "code": "WDJB-MJHT"}
```

`code` is there only for a device sign-in.

## Events

### Read events

`GET /v1/events`

Reads agents' [events](/reference/events/), as a JSON page or a server-sent event stream.

| Parameter | Type | Description |
| --- | --- | --- |
| `agents` | string, repeated | agent IDs to read |
| `types` | string, repeated | event types, like `wardrik.run.completed`; all unless set |
| `after` | string | the cursor to read after: a page's `next`, a streamed event's `id`, or a snapshot's `cursor` |
| `limit` | integer | events per page; 100 unless set |

```sh
curl "$WARDRIK_URL/v1/events?agents=agt_01JF8X5RQ2&types=wardrik.run.completed" \
  -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"events": [], "next": "W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ"}
```

Stream with `Accept: text/event-stream`:

```sh
curl -N "$WARDRIK_URL/v1/events" -H "Accept: text/event-stream" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```text
id: W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDJdXQ
data: {"specversion":"1.0","type":"wardrik.run.completed","agent":"agt_01JF8X5RQ2",...}
```

- Each event's `id` is a cursor. Reconnect with `Last-Event-ID` or `?after=` to resume.
- Without a cursor, a page starts at the oldest event; a stream starts at the next one written.
- Deltas carry no `id`.
- An idle stream sends a comment every 15 seconds.
- If the log was trimmed past your cursor, you get `wardrik.events.dropped`, whatever `types` says.

`GET /v1/agents/{agent}/events` reads one agent's log the same way.

### Read the head cursor

`GET /v1/events/head`

Returns the cursor at the end of every log, to start reading from now.

```sh
curl $WARDRIK_URL/v1/events/head -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"cursor": "W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ"}
```

### Read a timeline

`GET /v1/agents/{agent}/timeline`

Returns the conversation as a person reads it, oldest first.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/timeline -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{
  "items": [
    {"id": "msg_01", "kind": "user", "text": "What is on fire?", "sender": "acme/@ana"},
    {"id": "run_01", "kind": "run", "status": "completed",
     "steps": [{"id": "s1", "type": "text", "text": "Nothing right now.", "live": false}]}
  ],
  "cursor": "W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ"
}
```

A run's steps are `thinking`, `text` or `tool` (with `name`, `arguments`, `status`, `result`).

### Read runs

`GET /v1/agents/{agent}/runs`

Returns each run, newest first, with what it cost, and totals.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/runs -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{
  "runs": [{"id": "run_01", "status": "completed", "started_at": "2026-10-22T09:00:00Z",
            "finished_at": "2026-10-22T09:00:04Z", "duration_ms": 4120, "model": "anthropic:claude-sonnet-5",
            "tool_calls": 2, "tool_errors": 0, "input_tokens": 1830, "output_tokens": 212, "cost_micro_usd": 8670}],
  "totals": {"runs": 1, "failed": 0, "tool_calls": 2, "input_tokens": 1830, "output_tokens": 212,
             "cost_micro_usd": 8670, "last_at": "2026-10-22T09:00:04Z"},
  "cursor": "W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ"
}
```

## Triggers

### Set a trigger

`PUT /v1/agents/{agent}/triggers/{trigger}`

Sets or changes one trigger. Returns `404` if the agent has no definition.

The body takes the keys of a [trigger](/reference/agent-files/#triggers): `every`, `timezone`, `prompt`,
`prompt_file`, `overlap`, `missed`, `jitter`, `feed`, `webhook`.

```sh
curl -X PUT $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/triggers/sweep -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"every": "*/30 * * * *", "prompt": "Check the queue.", "overlap": "skip"}'
```

```json
{"every": "*/30 * * * *", "prompt": "Check the queue.", "overlap": "skip"}
```

A trigger whose `every` and `timezone` don't change keeps its next run.

### Remove a trigger

`DELETE /v1/agents/{agent}/triggers/{trigger}`

Stops and deletes the trigger. Returns it as it was.

```sh
curl -X DELETE $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/triggers/sweep -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"every": "*/30 * * * *", "prompt": "Check the queue.", "overlap": "skip"}
```

### Deliver a webhook

`POST /v1/hooks/{agent}/{trigger}`

Asks the agent about a request a service sent to its webhook trigger. Returns `202`.

- No token. The request proves itself with the trigger's secret, as `Authorization: Bearer` or a
  Standard Webhooks signature.
- The body is the service's own, in any content type. Wardrik takes it and its headers as sent.
- The same request is asked about once.
- `404` if there's no such trigger or the secret doesn't match. `503` means send it again later.

```sh
curl $WARDRIK_URL/v1/hooks/agt_01JF8X5RQ2/issues \
  -H "Authorization: Bearer s3cret" --json '{"action": "opened"}'
```

`POST /v1/hooks/{agent}/{trigger}/{secret}` does the same with the secret at the end of the path, for a
service that only takes a URL. Keep that URL as private as a token.

## Channels

### Deliver a chat app's request

`POST /v1/channels/{channel}/{path}`

Hands a chat app's request, like Slack's events, to the channel `config.yaml` names.

- No token. The channel checks the request's signature.
- The body is the chat app's own, in any content type.
- The response is the channel's status, headers and body, as the chat app expects them.
- `404` if no channel of that name takes requests.

```sh
curl $WARDRIK_URL/v1/channels/slack/events \
  -H "X-Slack-Signature: v0=a2114d57..." -H "X-Slack-Request-Timestamp: 1531420618" \
  --json '{"type": "url_verification", "challenge": "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P"}'
```

```text
3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P
```

See [Slack](/channels/slack/).

## Deployment

### List nodes

`GET /v1/deployment/nodes`

Lists the nodes, with how many agents run on each and how many sleep.

```sh
curl $WARDRIK_URL/v1/deployment/nodes -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"nodes": [{"name": "wardrik@box1", "agents": 12}, {"name": "wardrik@box2", "agents": 9}], "asleep": 40}
```

### Reload definitions

`POST /v1/deployment/reload`

Reads every agent's definition again, or those `?agents=` names. Each agent takes it from its next turn.

```sh
curl -X POST $WARDRIK_URL/v1/deployment/reload -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"reloaded": ["wardrik@box1"], "problems": ["agents/broken.md: There's no tool nope here."]}
```

### Read the audit log

`GET /v1/deployment/audit`

Returns a page of what people changed, oldest first.

| Parameter | Type | Description |
| --- | --- | --- |
| `starting_after` | integer | the sequence to read after, a page's `next` |
| `limit` | integer | changes per page; 100 unless set |

```sh
curl "$WARDRIK_URL/v1/deployment/audit?starting_after=11" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"events": [{"specversion": "1.0", "type": "wardrik.agent.defined", "...": "..."}], "next": 12}
```

Each change is a CloudEvent, like an agent's [events](/reference/events/).

## Daemon: agents

### Make an agent

`POST /v1/owners/{owner}/agents`

Mints an agent ID, keeps its record, and defines the agent. Returns `201`.

| Field | Type | Description |
| --- | --- | --- |
| `name` | string, required | unique in the org: letters, digits, `_`, `.`, `-` |
| any [definition](/reference/agent-files/#keys) key | | the agent's definition |

```sh
curl $WARDRIK_URL/v1/owners/acme%2F%40jon/agents -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"name": "notes", "model": "anthropic:claude-haiku-4-5", "instructions": "You keep Jon'\''s notes."}'
```

```json
{"id": "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN", "name": "notes", "org": "acme", "owner": "acme/@jon"}
```

`workspace.shared` names agents of the org by name. A name in use is a `409`.

### Find agents

`GET /v1/owners/{owner}/agents`

Lists the agents of the owner's org that the token may read.

| Parameter | Type | Description |
| --- | --- | --- |
| `name` | string | the agent's name; every agent unless set |

```sh
curl "$WARDRIK_URL/v1/owners/acme/agents?name=notes" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"agents": [{"id": "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN", "name": "notes", "org": "acme", "owner": "acme/@jon"}]}
```

## Daemon: secrets

### List secrets

`GET /v1/owners/{owner}/secrets`

Lists the owner's secret names and purposes. Never a value.

```sh
curl $WARDRIK_URL/v1/owners/acme/secrets -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"secrets": [{"name": "ANTHROPIC_API_KEY", "purpose": "api_key"}, {"name": "linear", "purpose": "grant"}]}
```

`purpose` is `api_key`, `client_secret`, `header`, `signing_secret`, `grant` (a connected account),
`token` (a chat app install) or `secret`.

### Seal a secret

`PUT /v1/owners/{owner}/secrets/{name}`

Seals a value under the name, replacing any old one. Returns `204`.

| Field | Type | Description |
| --- | --- | --- |
| `value` | string, required | the secret |
| `purpose` | string, required | `api_key`, `client_secret`, `header` or `signing_secret`; it's only read for that |

```sh
curl -X PUT $WARDRIK_URL/v1/owners/acme/secrets/ANTHROPIC_API_KEY -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"value": "sk-ant-0123456789abcdef", "purpose": "api_key"}'
```

The `deployment` owner's secrets are what `${NAME}` in `config.yaml` reads.

### Remove a secret

`DELETE /v1/owners/{owner}/secrets/{name}`

Removes the secret. Returns `204`, even if there was none.

```sh
curl -X DELETE $WARDRIK_URL/v1/owners/acme/secrets/ANTHROPIC_API_KEY -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Daemon: ceilings

### List ceilings

`GET /v1/owners/{owner}/ceilings`

Lists the org's spending ceilings, with what its agents spent this period.

```sh
curl $WARDRIK_URL/v1/owners/acme/ceilings -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"ceilings": [{"ceiling": "plan", "per": "month", "on_exhausted": "ask", "limit": {"usd": 20.0},
               "spent": {"usd": 12.4, "tokens": 81200}, "granted": {}, "starts_over": "2026-11-01"}]}
```

## Daemon: MCP servers

### List servers

`GET /v1/owners/{owner}/servers`

Lists the MCP servers the owner's agents reach: the owner's own, then the org's, then the deployment's.

```sh
curl $WARDRIK_URL/v1/owners/acme/servers -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"servers": [{"owner": "acme", "name": "crm", "source": "runtime", "url": "https://mcp.crm.example/mcp", "auth": "secret"},
             {"owner": "deployment", "name": "github", "source": "config", "url": "https://api.githubcopilot.com/mcp/", "auth": "oauth"}]}
```

### Add a server

`POST /v1/owners/{owner}/servers`

Adds an MCP server for the owner's agents. Its tools reach them from their next turn. Returns `201`.

| Field | Type | Description |
| --- | --- | --- |
| `name` | string, required | letters, digits, `-`, `_`, up to 32, never `__`; agents name its tools `name/*` |
| `url` | string, required | an `https` Streamable HTTP URL |
| `auth` | object, required | `{"none": {}}`, `{"secret": {"name": ..., "header": ..., "scheme": ...}}`, or `{"oauth": {...}}` |
| `only` | array | the server's tool names to take |
| `except` | array | the server's tool names to leave |

`oauth` takes `scopes`, and `provider` (an OAuth app's name) or `issuer`, `client_id` and `client_secret`.
Left empty, the daemon finds the server's own sign-in.

```sh
curl $WARDRIK_URL/v1/owners/acme/servers -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"name": "crm", "url": "https://mcp.crm.example/mcp", "auth": {"oauth": {}}}'
```

```json
{"server": "crm", "connected": false, "authorization": {"url": "https://auth.crm.example/authorize?client_id=…&state=…"}}
```

### Remove a server

`DELETE /v1/owners/{owner}/servers/{name}`

Removes one of the owner's own servers, and forgets the sign-ins to it.

```sh
curl -X DELETE $WARDRIK_URL/v1/owners/acme/servers/crm -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"owner": "acme", "name": "crm", "source": "runtime", "url": "https://mcp.crm.example/mcp", "auth": "secret"}
```

## Daemon: notify targets

### List notify targets

`GET /v1/owners/{owner}/notify_targets`

Lists where the owner's agents' notices can go: the owner's own, then the org's, then the deployment's.

```sh
curl $WARDRIK_URL/v1/owners/acme/notify_targets -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"targets": [{"owner": "acme", "name": "ops", "source": "runtime", "kind": "webhook",
              "url": "https://hooks.acme.example/wardrik", "secret": {"name": "OPS_HOOK_SECRET"}}]}
```

### Add a notify target

`POST /v1/owners/{owner}/notify_targets`

Adds a webhook that agents' notices are posted to. Returns `201`.

| Field | Type | Description |
| --- | --- | --- |
| `name` | string, required | what definitions name in `notify`; letters, digits, `-`, `_`, up to 32 |
| `url` | string, required | an `https` URL; redirects aren't followed |
| `secret.name` | string | a vault secret that signs each notice |

```sh
curl $WARDRIK_URL/v1/owners/acme/notify_targets -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"name": "ops", "url": "https://hooks.acme.example/wardrik", "secret": {"name": "OPS_HOOK_SECRET"}}'
```

```json
{"owner": "acme", "name": "ops", "source": "runtime", "kind": "webhook",
 "url": "https://hooks.acme.example/wardrik", "secret": {"name": "OPS_HOOK_SECRET"}}
```

### Remove a notify target

`DELETE /v1/owners/{owner}/notify_targets/{name}`

Removes one of the owner's own targets. Returns it as it was.

```sh
curl -X DELETE $WARDRIK_URL/v1/owners/acme/notify_targets/ops -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Daemon: OAuth apps

### List OAuth apps

`GET /v1/owners/{owner}/providers`

Lists the OAuth apps the owner's people sign in with. Never a client secret.

```sh
curl $WARDRIK_URL/v1/owners/acme/providers -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"providers": [{"owner": "deployment", "name": "google", "source": "runtime", "issuer": "https://accounts.google.com",
                "client_id": "868288504182-example.apps.googleusercontent.com", "client_secret": {"name": "GOOGLE_CLIENT_SECRET"},
                "scopes": ["https://www.googleapis.com/auth/adwords"], "client_auth": "post", "flow": "browser"}]}
```

### Add an OAuth app

`POST /v1/owners/{owner}/providers`

Adds an OAuth app for the owner's people. Returns `201`.

| Field | Type | Description |
| --- | --- | --- |
| `name` | string, required | the account it grants; letters, digits, `-`, `_`, up to 32 |
| `issuer` | string | the issuer URL; its metadata names the endpoints |
| `resource` | string | the API its tokens are for; finds the issuer if none is given |
| `authorization_endpoint`, `token_endpoint` | string | for a service without metadata |
| `client_id` | string | the app's client ID |
| `client_secret.name` | string | a vault secret sealed as `client_secret` |
| `client_auth` | string | `post` (default) or `basic` |
| `scopes` | array | scopes to ask for |
| `flow` | string | `browser` (default) or `device` |
| `authorization_params` | object | extra browser sign-in params, like `access_type` |

It needs `issuer`, `resource`, or both endpoints.

```sh
curl $WARDRIK_URL/v1/owners/acme/providers -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"name": "x", "authorization_endpoint": "https://x.com/i/oauth2/authorize",
           "token_endpoint": "https://api.x.com/2/oauth2/token", "client_id": "cnh3-example",
           "client_secret": {"name": "X_CLIENT_SECRET"}, "client_auth": "basic",
           "scopes": ["tweet.read", "tweet.write", "offline.access"]}'
```

Returns the app as it's kept, as [List OAuth apps](#list-oauth-apps) shows it.

### Remove an OAuth app

`DELETE /v1/owners/{owner}/providers/{name}`

Removes one of the owner's own apps. Returns it as it was.

```sh
curl -X DELETE $WARDRIK_URL/v1/owners/acme/providers/x -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Daemon: connections

Your own connected accounts. A token always manages its own.

### List connections

`GET /v1/connections`

Lists the accounts you can connect, and whether you hold each.

```sh
curl $WARDRIK_URL/v1/connections -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"connections": [{"provider": "github", "connected": true, "signing_in": false},
                 {"provider": "linear", "connected": false, "signing_in": true}]}
```

| Field | Type | Description |
| --- | --- | --- |
| `provider` | string | an OAuth app's name, or an MCP server's with its own sign-in |
| `connected` | boolean | whether you hold it |
| `signing_in` | boolean | whether a sign-in you started is still under way |

### Connect an account

`POST /v1/connections/{provider}`

Starts your sign-in, or says you hold the account already.

```sh
curl -X POST $WARDRIK_URL/v1/connections/github -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"provider": "github", "connected": false, "authorization": {"url": "https://github.com/login/device", "code": "WDJB-MJHT"}}
```

Open `authorization.url`. A device sign-in shows `code` to enter there.

### Finish a browser sign-in

`POST /v1/connections/{provider}/pair`

Sends the code the sign-in page showed. Five wrong codes end the sign-in.

| Field | Type | Description |
| --- | --- | --- |
| `code` | string, required | the code, as `BCDF-GHJK` |

```sh
curl $WARDRIK_URL/v1/connections/linear/pair -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"code": "BCDF-GHJK"}'
```

```json
{"provider": "linear", "connected": true, "signing_in": false}
```

### Disconnect an account

`DELETE /v1/connections/{provider}`

Forgets your account. The next call that needs it asks you to sign in again. Returns `204`, or
`404` if you hold no such account.

```sh
curl -X DELETE $WARDRIK_URL/v1/connections/github -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Daemon: tokens

### List tokens

`GET /v1/tokens`

Lists every token. Never a secret.

```sh
curl $WARDRIK_URL/v1/tokens -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"tokens": [{"id": "mzxw6ytboi", "name": "ana's laptop", "subject": "user:acme/@ana",
             "groups": ["payments-eng"], "expires": "2026-12-01T00:00:00Z"}]}
```

### Create a token

`POST /v1/tokens`

Creates a token that acts as `subject`. Returns `201` with the secret, shown once.

| Field | Type | Description |
| --- | --- | --- |
| `name` | string, required | what it's for |
| `subject` | string, required | a person, as `user:acme/@ana`, or `agent:ID` for an agent's own |
| `groups` | array | the user's groups, which [bindings](/reference/config/#roles-and-bindings) can name |
| `expires_in` | integer | seconds, from 60 to a year; 30 days unless set |

```sh
curl $WARDRIK_URL/v1/tokens -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"name": "ana laptop", "subject": "user:acme/@ana", "groups": ["payments-eng"], "expires_in": 2592000}'
```

```json
{"id": "mzxw6ytboi", "name": "ana laptop", "subject": "user:acme/@ana", "groups": ["payments-eng"],
 "expires": "2026-12-01T00:00:00Z", "secret": "wdk_mzxw6ytboi_0123456789abcdef"}
```

Only the `admin` user can make a `user:admin` token.

### Revoke a token

`DELETE /v1/tokens/{id}`

Revokes the token at once. Returns `204`.

```sh
curl -X DELETE $WARDRIK_URL/v1/tokens/mzxw6ytboi -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Tool workers

`GET /v1/workers` is a WebSocket for an MCP server that dials in. See [Tools in your app](/build/tool-workers/).

- Messages are JSON-RPC 2.0, one per text frame, as MCP `2025-06-18`.
- Wardrik is the client. It sends `initialize`, `tools/list`, `tools/call` and `notifications/cancelled`.
- A call's `_meta` has the `agent` it's for and an `idempotencyKey`. Answer with `_meta.costUsd` to report cost.
- Agents whose `tools` include `workers/*` get the worker's tools as `workers__NAME`.
- A plain request with a working token returns `426`. The socket closes with `1008` once the token stops working.
