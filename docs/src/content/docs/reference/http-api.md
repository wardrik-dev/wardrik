---
title: "HTTP API"
description: "HTTP routes, authentication, request fields, responses, and event streaming."
sidebar:
  order: 5
---

The daemon exposes a JSON API for agents, messages, approvals, and configuration.
Create an API token with `wardrik token create`, then set `WARDRIK_TOKEN` to the returned value.

```sh
export WARDRIK_URL=http://127.0.0.1:4747
curl $WARDRIK_URL/v1/agents -H "Authorization: Bearer $WARDRIK_TOKEN"
```

- The daemon listens on `127.0.0.1:4747`. Set [`http`](/reference/config/#http) in `config.yaml` to change it.
- Authenticated API routes require `Authorization: Bearer <token>`. Webhooks and chat apps
  authenticate with their integration secrets or signatures instead. See [`wardrik token create`](/reference/cli/#tokens).
- Bodies are JSON, up to 8 MB. Webhook and chat app routes accept bodies in any format.
- Responses include a `request-id` header. If the request includes one, the server returns the same value.
- `GET /v1/openapi.json` returns the OpenAPI 3.1 document for the library's routes.
  The daemon's own routes (`/v1/owners/...`, `/v1/connections`, `/v1/tokens`) are in `wardrik_daemon`'s
  `priv/openapi.json`.
- See [Use the HTTP API](/build/http-api/) for a step-by-step guide.

## Errors

```json
{"error": {"type": "not_found", "message": "No agent runs under agt_01JF8X5RQ2."}}
```

| `type` | Status | When |
| --- | --- | --- |
| `invalid_request` | `400` | malformed or invalid input |
| `unauthorized` | `401` | missing, unknown, revoked or expired token |
| `forbidden` | `403` | the token isn't allowed to do this |
| `not_found` | `404` | doesn't exist, or the token can't access it |
| `conflict` | `409` | conflicts with current state: no such pending call, agent busy, or defined by a file |
| `internal` | `500` | a server bug |
| `not_supported` | `501` | not supported yet |
| `unavailable` | `503` | temporarily unavailable, such as the store; retry later |

## IDs in paths

- `{agent}` is a daemon-generated agent ID: `agt_01JF8X5RQ2`. URL-encode it as one segment.
- `{owner}` is one URL-encoded segment: `acme` (an org), `acme%2F%40jon` (a user), or `deployment`.
- `?agents=` takes agent IDs, one per `agents=`. If omitted, it means every agent the token can access,
  except on `/v1/events` and `/v1/events/head`, which need it.

### Conversations

An agent has many conversations. To target one, append `/conversations/{conversation}` to the agent path:

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/conversations/C1/messages \
  -H "Authorization: Bearer $WARDRIK_TOKEN" --json '{"content": "Hi"}'
```

These routes support the conversation path: read, clear (`DELETE .../conversations/{conversation}`),
messages, decisions, approve, deny, authorization, cancel, stop, events, timeline, runs, calls, stop a
call, and move.

- Clearing a conversation deletes its history. The conversation ID still accepts messages.
- In `openapi.json`, a conversation route has no `operationId`. Its `x-wardrik-operation` names the
  operation it serves, such as `agent.ask`.

## Agents

### List agents

`GET /v1/agents`

Lists the agents the token can access.

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

Returns the agent's current status and activity.

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
| `status` | string | `idle`, `running`, `parked` (pending approval) or `asleep` |
| `node` | string or null | the node it runs on; `null` while asleep |
| `pending` | integer | messages queued behind the current one |
| `activity` | object | what it's doing, as [`activity`](/reference/events/#shared-types) |
| `interrupts` | array | calls pending approval |
| `cursor` | string | current event-log cursor; pass as `after` to read subsequent events |
| `next_run` | string or null | when its next clock trigger runs |
| `spent_today` | object | what it spent today |

### Define an agent

`PUT /v1/agents/{agent}`

Starts the agent with the definition, or updates a running agent from its next turn.

The body is an [agent definition](/reference/agent-files/#keys). The daemon only accepts IDs it generated, so
create the agent with [`POST /v1/owners/{owner}/agents`](#make-an-agent) first.

```sh
curl -X PUT $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2 -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"instructions": "You watch the incident queue.", "model": "anthropic:claude-sonnet-5", "tools": ["web_search"]}'
```

Returns the agent, as [Read an agent](#read-an-agent) does. An unsupported key returns `501`.

### Read a definition

`GET /v1/agents/{agent}/definition`

Returns the current definition, and lists its tools that aren't available yet.

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
| `missing` | array | configured tools that are unavailable, such as tools from a disconnected MCP server |
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

Stops the agent's process. The conversation is kept. The next message starts it again.

```sh
curl -X POST $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/stop -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"agent": {"id": "agt_01JF8X5RQ2", "status": "asleep", "pending": 0}}
```

### Clear an agent's history

`DELETE /v1/agents/{agent}/conversation`

Clears the agent's history. The agent, its definition and its other conversations are kept. Returns
`409` while a turn is running or pending approval.

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

Removes each agent in `?agents=`, or every agent the token can access.

| Parameter | Type | Description |
| --- | --- | --- |
| `agents` | string, repeated | agent IDs to forget |

```sh
curl -X DELETE "$WARDRIK_URL/v1/agents?agents=agt_01JF8X5RQ2" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"forgotten": ["agt_01JF8X5RQ2"], "kept": [], "failed": []}
```

Entries in `kept` and `failed` contain `{"id": ..., "why": ...}`. Agents defined by files
are kept; remove their files to delete them.

### Read an agent's resource use

`GET /v1/agents/{agent}/runtime`

Returns a running agent's memory, mailbox size, process count and reductions. The figures include
its current turn and running tool calls. Returns `404` while the agent sleeps.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/runtime -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"agent": "agt_01JF8X5RQ2", "node": "wardrik@box1", "memory_bytes": 1843200, "binary_bytes": 524288,
 "processes": 3, "message_queue": 0, "reductions": 4810233}
```

### Read what an agent gets

`GET /v1/agents/{agent}/resolved`

Returns what the agent gets from its owner and config: the user it works for, its policies, MCP
servers and the tools each offers now, notify targets, channels and workspaces.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/resolved -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"agent": "agt_01JF8X5RQ2", "principal": {"id": "user_42"},
 "servers": [{"name": "github", "server": "acme:github", "tools": ["github__search_issues", "github__create_issue"]}],
 "policy": [{"deny": ["shell/*"]}], "policies": {}, "defaults": {"model": "anthropic:claude-haiku-4-5"},
 "notify": [{"name": "ops", "target": "ops"}], "channels": {"slack": "T0123"}, "workspaces": {"agt_runbooks": "read"}}
```

### Move an agent

`POST /v1/agents/{agent}/move`

Restarts the agent on another node. A running turn ends. Send the message again after the move.

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
| `id` | string | client-supplied message ID; repeated requests with the same ID are deduplicated |

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

Ends the current turn of each agent in `?agents=`, or every agent the token can access. Returns `202`.

```sh
curl -X POST "$WARDRIK_URL/v1/agents/cancel?agents=agt_01JF8X5RQ2" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"cancelled": ["agt_01JF8X5RQ2"]}
```

### List running tool calls

`GET /v1/agents/{agent}/calls`

Lists the agent's running tool calls. Returns `404` while its process is stopped.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/calls -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"calls": [{"id": "toolu_01", "name": "github__search_issues", "elapsed_ms": 1250}]}
```

### Stop a tool call

`DELETE /v1/agents/{agent}/calls/{call}`

Stops one tool call. The model receives an error and the turn continues. Returns `204`.

```sh
curl -X DELETE $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/calls/toolu_01 -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Approvals

### List waiting calls

`GET /v1/interrupts`

Lists calls pending approval.

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

An entry has `conversation` when the call is in a conversation.

### Approve a call

`POST /v1/agents/{agent}/interrupts/{interrupt}/approve`

Approves one call. It runs with the model's arguments.

| Field | Type | Description |
| --- | --- | --- |
| `note` | string | text the model receives with the call's result |

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/interrupts/toolu_01/approve \
  -H "Authorization: Bearer $WARDRIK_TOKEN" --json '{"note": "Only staging."}'
```

```json
{"decisions": [{"id": "toolu_01", "decision": "approved"}]}
```

### Deny a call

`POST /v1/agents/{agent}/interrupts/{interrupt}/deny`

Denies one call.

| Field | Type | Description |
| --- | --- | --- |
| `reason` | string | text the model receives instead of the call's result |

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/interrupts/toolu_01/deny \
  -H "Authorization: Bearer $WARDRIK_TOKEN" --json '{"reason": "Not this quarter."}'
```

```json
{"decisions": [{"id": "toolu_01", "decision": "rejected"}]}
```

### Decide many calls

`POST /v1/agents/{agent}/decisions`

Approves or denies several pending calls at once.

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

Returns the sign-in URL for a call pending with reason `authorization`.

```sh
curl $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/interrupts/toolu_01/authorization \
  -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"url": "https://github.com/login/device", "code": "WDJB-MJHT"}
```

`code` is included only for a device sign-in.

## Events

### Read events

`GET /v1/events`

Returns agents' [events](/reference/events/), as a JSON page or a server-sent event stream.

| Parameter | Type | Description |
| --- | --- | --- |
| `agents` | string, repeated | required: the agent IDs to read |
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
curl -N "$WARDRIK_URL/v1/events?agents=agt_01JF8X5RQ2" -H "Accept: text/event-stream" \
  -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```text
id: W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDJdXQ
data: {"specversion":"1.0","type":"wardrik.run.completed","agent":"agt_01JF8X5RQ2",...}
```

- The SSE `id:` line contains a cursor, distinct from the CloudEvent’s ID inside the JSON payload.
  To resume, pass the cursor as `Last-Event-ID` or `?after=`.
- Without a cursor, a page starts at the oldest event, and a stream starts at the next new event.
- Deltas have no `id`.
- An idle stream sends a comment every 15 seconds.
- If the log was trimmed past your cursor, you receive `wardrik.events.dropped`, regardless of `types`.

`GET /v1/agents/{agent}/events` reads one agent's log the same way.

### Read the head cursor

`GET /v1/events/head`

Returns the current end-of-log cursor of each agent in `?agents=`, to read only new events.

```sh
curl "$WARDRIK_URL/v1/events/head?agents=agt_01JF8X5RQ2" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"cursor": "W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ"}
```

### Read a timeline

`GET /v1/agents/{agent}/timeline`

Returns the conversation in readable form, oldest first.

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

Returns each turn, newest first, with its cost, and totals.

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

The body has the keys of a [trigger](/reference/agent-files/#triggers): `every`, `timezone`, `prompt`,
`prompt_file`, `overlap`, `missed`, `jitter`, `feed`, `webhook`.

```sh
curl -X PUT $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/triggers/sweep -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"every": "*/30 * * * *", "prompt": "Check the queue.", "overlap": "skip"}'
```

```json
{"every": "*/30 * * * *", "prompt": "Check the queue.", "overlap": "skip"}
```

If `every` and `timezone` are unchanged, the trigger keeps its next run time.

### Remove a trigger

`DELETE /v1/agents/{agent}/triggers/{trigger}`

Deletes the trigger. Returns its last state.

```sh
curl -X DELETE $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/triggers/sweep -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"every": "*/30 * * * *", "prompt": "Check the queue.", "overlap": "skip"}
```

### Deliver a webhook

`POST /v1/hooks/{agent}/{trigger}`

Sends a webhook request to the agent's webhook trigger. Returns `202`.

- No token. The request authenticates with the trigger's secret, as `Authorization: Bearer` or a
  Standard Webhooks signature.
- The body can be any content type. Wardrik passes the body and headers to the agent as sent.
- A repeated request sends one message.
- `404` if the trigger doesn't exist or the secret doesn't match. `503` means retry later.

```sh
curl $WARDRIK_URL/v1/hooks/agt_01JF8X5RQ2/issues \
  -H "Authorization: Bearer s3cret" --json '{"action": "opened"}'
```

`POST /v1/hooks/{agent}/{trigger}/{secret}` takes the secret as the last path segment, for services
that only accept a URL. Treat that URL as a secret.

## Files

Files in an agent's workspace. Roles grant reading them as the verb `files`, and writing and
deleting as `file_put` and `file_delete`.

### List files

`GET /v1/agents/{agent}/files`

Returns up to 500 files, newest first, without their content. `glob`, such as `skills/**`, limits
the paths.

```sh
curl "$WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/files?glob=skills/**" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"files": [{"path": "skills/triage/SKILL.md", "version": "3", "bytes": 812, "by": "user_42",
 "at": "2026-11-11T12:00:00Z", "labels": []}]}
```

### Read a file

`GET /v1/agents/{agent}/file?path=PATH`

Returns the file and its content. Returns `404` if there's no file at the path.

```sh
curl "$WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/file?path=MEMORY.md" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"file": {"path": "MEMORY.md", "version": "7", "bytes": 10, "by": "agt_01JF8X5RQ2",
 "at": "2026-11-11T12:00:00Z", "labels": []}, "content": "Likes tea."}
```

### Write a file

`PUT /v1/agents/{agent}/file`

| Field | Type | Description |
| --- | --- | --- |
| `path` | string, required | the path in the workspace |
| `content` | string, required | the text, up to 4 MiB |
| `version` | string | write only over this version; `409` if the file changed |

Without `version`, the write replaces any file at the path. The file has no labels. Returns the
file without its content.

```sh
curl -X PUT $WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/file -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"path": "MEMORY.md", "content": "Likes tea."}'
```

### Delete a file

`DELETE /v1/agents/{agent}/file?path=PATH`

Returns `204`, or `404` if there's no file at the path.

```sh
curl -X DELETE "$WARDRIK_URL/v1/agents/agt_01JF8X5RQ2/file?path=MEMORY.md" -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Channels

### Deliver a chat app's request

`POST /v1/channels/{channel}/{path}`

Routes a chat app's request, such as a Slack event, to the named channel in `config.yaml`.

- No token. The channel verifies the request's signature.
- The body can be any content type.
- The response is the channel's status, headers and body, in the chat app's format.
- `404` if no channel with that name accepts requests.

```sh
curl $WARDRIK_URL/v1/channels/slack/events \
  -H "X-Slack-Signature: v0=a2114d57..." -H "X-Slack-Request-Timestamp: 1531420618" \
  --json '{"type": "url_verification", "challenge": "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P"}'
```

```text
3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P
```

See [Slack](/build/slack/).

## Deployment

### List nodes

`GET /v1/deployment/nodes`

Lists the nodes and how many agents run on each. `running`, `idle` and `parked` count those
agents by status. `asleep` counts the agents on no node.

```sh
curl $WARDRIK_URL/v1/deployment/nodes -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"nodes": [{"name": "wardrik@box1", "agents": 12}, {"name": "wardrik@box2", "agents": 9}],
 "running": 5, "idle": 14, "parked": 2, "asleep": 40}
```

### Read resource use

`GET /v1/deployment/runtime`

Returns each node's resource use, and the running agents that use the most memory.

| Parameter | Type | Description |
| --- | --- | --- |
| `limit` | integer | how many agents to return; 20 unless set |

```sh
curl $WARDRIK_URL/v1/deployment/runtime -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"nodes": [{"name": "wardrik@box1", "agents": 12, "scheduler_utilization": 0.12, "run_queue": 0,
            "memory": {"total": 98566144, "processes": 31457280, "code": 25165824, "resident": 163577856, "...": "..."},
            "process_groups": [{"module": "WardrikCore.Agent", "application": "wardrik_core", "processes": 12, "memory_bytes": 1572864}],
            "processes": {"count": 1203, "limit": 1048576}, "...": "..."}],
 "agents": [{"agent": "triage", "node": "wardrik@box1", "memory_bytes": 1843200, "processes": 3, "...": "..."}]}
```

- `memory` is in bytes. `resident` is what the operating system reports, on Linux only.
- `process_groups` counts processes by the module that runs them, most first.
- With `os_mon` running, `os` adds the machine's load, memory and disks.

### Reload definitions

`POST /v1/deployment/reload`

Rereads every agent's definition, or those in `?agents=`. Each applies from the agent's next turn.

```sh
curl -X POST $WARDRIK_URL/v1/deployment/reload -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"reloaded": ["wardrik@box1"], "problems": ["agents/broken.md: There's no tool nope here."]}
```

### Read the audit log

`GET /v1/deployment/audit`

Returns a page of the audit log, oldest first.

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

Each entry is a CloudEvent, like an agent's [events](/reference/events/).

## Daemon: agents

### Make an agent

`POST /v1/owners/{owner}/agents`

Generates an agent ID, stores the record, and defines the agent. Returns `201`.

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

Lists the agents in the owner's org that the token can read.

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

Lists the owner's secret names and purposes, never values.

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

Stores an encrypted value under the name, replacing any existing one. Returns `204`.

| Field | Type | Description |
| --- | --- | --- |
| `value` | string, required | the secret |
| `purpose` | string, required | `api_key`, `client_secret`, `header` or `signing_secret`; it's only read for that |

```sh
curl -X PUT $WARDRIK_URL/v1/owners/acme/secrets/ANTHROPIC_API_KEY -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"value": "sk-ant-0123456789abcdef", "purpose": "api_key"}'
```

`${NAME}` in `config.yaml` resolves the `deployment` owner's secrets.

### Remove a secret

`DELETE /v1/owners/{owner}/secrets/{name}`

Removes the secret. Returns `204`, even if it didn't exist.

```sh
curl -X DELETE $WARDRIK_URL/v1/owners/acme/secrets/ANTHROPIC_API_KEY -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Daemon: ceilings

### List ceilings

`GET /v1/owners/{owner}/ceilings`

Lists organization spending thresholds (called `ceilings` in the API), including spending
and approved extensions for the current period.

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

Lists the MCP servers available to the owner's agents: the owner's, then the org's, then the deployment's.

```sh
curl $WARDRIK_URL/v1/owners/acme/servers -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"servers": [{"owner": "acme", "name": "crm", "source": "runtime", "url": "https://mcp.crm.example/mcp", "auth": "secret"},
             {"owner": "deployment", "name": "github", "source": "config", "url": "https://api.githubcopilot.com/mcp/", "auth": "oauth"}]}
```

### Add a server

`POST /v1/owners/{owner}/servers`

Adds an MCP server for the owner's agents. Its tools are available from their next turn. Returns `201`.

| Field | Type | Description |
| --- | --- | --- |
| `name` | string, required | letters, digits, `-`, `_`, up to 32, never `__`; agents name its tools `name/*` |
| `url` | string, required | an `https` Streamable HTTP URL |
| `auth` | object, required | `{"none": {}}`, `{"secret": {"name": ..., "header": ..., "scheme": ...}}`, or `{"oauth": {...}}` |
| `only` | array | tool names to include |
| `except` | array | tool names to exclude |

`oauth` takes `scopes`, and `provider` (an OAuth app's name) or `issuer`, `client_id` and `client_secret`.
If empty, the daemon discovers the server's OAuth metadata.

```sh
curl $WARDRIK_URL/v1/owners/acme/servers -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"name": "crm", "url": "https://mcp.crm.example/mcp", "auth": {"oauth": {}}}'
```

```json
{"server": "crm", "connected": false, "authorization": {"url": "https://auth.crm.example/authorize?client_id=…&state=…"}}
```

### Remove a server

`DELETE /v1/owners/{owner}/servers/{name}`

Removes one of the owner's servers, and deletes its sign-ins.

```sh
curl -X DELETE $WARDRIK_URL/v1/owners/acme/servers/crm -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"owner": "acme", "name": "crm", "source": "runtime", "url": "https://mcp.crm.example/mcp", "auth": "secret"}
```

## Daemon: notify targets

### List notify targets

`GET /v1/owners/{owner}/notify_targets`

Lists the notice targets available to the owner's agents: the owner's, then the org's, then the deployment's.

```sh
curl $WARDRIK_URL/v1/owners/acme/notify_targets -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"targets": [{"owner": "acme", "name": "ops", "source": "runtime", "kind": "webhook",
              "url": "https://hooks.acme.example/wardrik", "secret": {"name": "OPS_HOOK_SECRET"}}]}
```

### Add a notify target

`POST /v1/owners/{owner}/notify_targets`

Adds a notice webhook. Returns `201`.

| Field | Type | Description |
| --- | --- | --- |
| `name` | string, required | destination name used in `notify`; up to 32 letters, digits, `-`, or `_` |
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

Removes one of the owner's targets. Returns its last state.

```sh
curl -X DELETE $WARDRIK_URL/v1/owners/acme/notify_targets/ops -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Daemon: OAuth apps

### List OAuth apps

`GET /v1/owners/{owner}/providers`

Lists the owner's OAuth apps, never client secrets.

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

Adds an OAuth app for the owner's users. Returns `201`.

| Field | Type | Description |
| --- | --- | --- |
| `name` | string, required | the account it grants; letters, digits, `-`, `_`, up to 32 |
| `issuer` | string | the issuer URL; its metadata names the endpoints |
| `resource` | string | the API its tokens are for; finds the issuer if none is given |
| `authorization_endpoint`, `token_endpoint` | string | for a service without metadata |
| `client_id` | string | the app's client ID |
| `client_secret.name` | string | a vault secret stored as `client_secret` |
| `client_auth` | string | `post` (default) or `basic` |
| `scopes` | array | scopes to ask for |
| `flow` | string | `browser` (default) or `device` |
| `authorization_params` | object | extra browser sign-in params, like `access_type` |

It requires `issuer`, `resource`, or both endpoints.

```sh
curl $WARDRIK_URL/v1/owners/acme/providers -H "Authorization: Bearer $WARDRIK_TOKEN" \
  --json '{"name": "x", "authorization_endpoint": "https://x.com/i/oauth2/authorize",
           "token_endpoint": "https://api.x.com/2/oauth2/token", "client_id": "cnh3-example",
           "client_secret": {"name": "X_CLIENT_SECRET"}, "client_auth": "basic",
           "scopes": ["tweet.read", "tweet.write", "offline.access"]}'
```

Returns the stored app, in the format of [List OAuth apps](#list-oauth-apps).

### Remove an OAuth app

`DELETE /v1/owners/{owner}/providers/{name}`

Removes one of the owner's apps. Returns its last state.

```sh
curl -X DELETE $WARDRIK_URL/v1/owners/acme/providers/x -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Daemon: connections

These routes manage the connected accounts of the authenticated user. Users can manage only
their own connections.

### List connections

`GET /v1/connections`

Lists the available providers, and whether each is connected.

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
| `connected` | boolean | whether it's connected |
| `signing_in` | boolean | whether a sign-in you started is still under way |

### Connect an account

`POST /v1/connections/{provider}`

Starts a sign-in, or returns `connected: true` if already connected.

```sh
curl -X POST $WARDRIK_URL/v1/connections/github -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"provider": "github", "connected": false, "authorization": {"url": "https://github.com/login/device", "code": "WDJB-MJHT"}}
```

Open `authorization.url`. For a device sign-in, enter `code` there.

### Finish a browser sign-in

`POST /v1/connections/{provider}/pair`

Completes a browser sign-in with the code from its page. Five wrong codes cancel the sign-in.

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
`404` if there is no such connection.

```sh
curl -X DELETE $WARDRIK_URL/v1/connections/github -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Daemon: tokens

### List tokens

`GET /v1/tokens`

Lists every token, never secrets.

```sh
curl $WARDRIK_URL/v1/tokens -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"tokens": [{"id": "mzxw6ytboi", "name": "ana's laptop", "subject": "user:acme/@ana",
             "groups": ["payments-eng"], "expires": "2026-12-01T00:00:00Z"}]}
```

### Create a token

`POST /v1/tokens`

Creates a token that authenticates as `subject`. Returns `201` with the secret, shown once.

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

Only the `admin` user can create a `user:admin` token.

### Create a sign-in link

`POST /v1/tokens/web`

Returns a link that signs the caller in to the [dashboard](/run/dashboard/). The link works for
two minutes. Signing in creates a token for the caller that lasts 12 hours. Only user tokens can
sign in. Returns `404` while `web.enabled` is `false`.

```sh
curl -X POST $WARDRIK_URL/v1/tokens/web -H "Authorization: Bearer $WARDRIK_TOKEN"
```

```json
{"url": "http://127.0.0.1:4747/web/sign-in?code=..."}
```

### Revoke a token

`DELETE /v1/tokens/{id}`

Revokes the token immediately. Returns `204`.

```sh
curl -X DELETE $WARDRIK_URL/v1/tokens/mzxw6ytboi -H "Authorization: Bearer $WARDRIK_TOKEN"
```

## Tool workers

`GET /v1/workers` accepts outbound WebSocket connections from tool workers. See [Tools in your app](/build/tool-workers/).

- Messages are JSON-RPC 2.0, one per text frame, as MCP `2025-06-18`.
- Wardrik is the client. It sends `initialize`, `tools/list`, `tools/call` and `notifications/cancelled`.
- A call's `_meta` has the calling `agent` and an `idempotencyKey`. Return `_meta.costUsd` to report cost.
- Agents with `workers/*` in `tools` see the worker's tools as `workers__NAME`.
- A non-WebSocket request with a valid token returns `426`. The socket closes with `1008` when the token is revoked or expires.
