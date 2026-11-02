---
title: Use the HTTP API
description: "Make an agent, ask it something, follow its answer and decide what it waits on, over HTTP or with the TypeScript SDK."
sidebar:
  order: 4
---

The daemon serves a JSON API on `127.0.0.1:4747`. The [HTTP API reference](/reference/http-api/)
lists every route.

## A token

```sh
wardrik token create jon-laptop --subject user:acme/@jon
export TOKEN=wdk_...
```

- The secret is printed once. Send it as `authorization: Bearer`.
- `acme/@jon` is Jon in the org `acme`. He may do anything to agents he owns.
- Anything else needs a binding in `config.yaml`. See [Orgs, roles and tokens](/run/orgs/).

## Make an agent

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/owners/acme%2F%40jon/agents \
  -d '{
    "name": "triage",
    "model": "anthropic:claude-sonnet-5",
    "instructions": "You watch the incident queue, and say what needs an engineer.",
    "tools": ["linear/*"],
    "policy": {"ask": ["linear/create_*"]}
  }'
# {"id": "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN", "name": "triage", "org": "acme", "owner": "acme/@jon"}

export AGENT=agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN
```

- The daemon mints the agent's ID. Every other route takes it.
- `{owner}` is one URL-encoded segment: `acme` for the org, `acme%2F%40jon` for Jon.
- A definition takes the keys of an [agent file](/reference/agent-files/).
- `PUT /v1/agents/$AGENT` with a definition replaces it, from the agent's next turn.
- `GET /v1/owners/acme/agents?name=triage` finds an agent by name.

## Ask it something

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/$AGENT/messages \
  -d '{"content": "What is on fire?"}'
# {"message": {"id": "msg_01…", "cursor": "W1siYWd0XzAxSkY4…"}}
```

It answers `202` at once. `POST /v1/agents/$AGENT/conversations/C1/messages` talks in a
conversation of its own, with its own history.

## Follow the answer

```sh
curl -N -H "authorization: Bearer $TOKEN" -H "accept: text/event-stream" \
  "http://127.0.0.1:4747/v1/agents/$AGENT/events?after=$CURSOR"
```

- `after` is the message's `cursor`, so nothing of its turn is missed.
- The answer arrives as `wardrik.message.delta`, then `wardrik.message.completed` and
  `wardrik.run.completed`.
- Without `accept: text/event-stream`, it answers one page. See [Events](/concepts/events/).

## Decide what it waits on

A waiting call arrives as `wardrik.run.interrupted`, with an `id` for each call:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/$AGENT/decisions \
  -d '{"decisions": [{"id": "call_1", "decision": "approve", "note": "Label it for the next sprint."}]}'
```

- `"decision": "reject"` with a `"reason"` refuses it.
- `POST .../interrupts/{id}/approve` and `.../deny` decide one call.
- A note reaches the model beside the result. See [Approvals](/concepts/approvals/).

## With the TypeScript SDK

```sh
npm install @wardrik/sdk@0.1.0-rc.2 zod
```

```ts
import { Wardrik } from "@wardrik/sdk";

const wardrik = new Wardrik(); // WARDRIK_URL, else http://127.0.0.1:4747; WARDRIK_TOKEN
const agent = wardrik.agent(process.env.AGENT!);

for await (const event of agent.stream("What is on fire?")) {
  if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);

  if (event.type === "wardrik.run.interrupted") {
    for (const interrupt of event.data.interrupts) await agent.approve(interrupt.id);
  }
}
```

- `agent.reply("...")` resolves once the run ends or waits.
- The SDK covers Wardrik's routes. The daemon's own, under `/v1/owners`, `/v1/connections` and
  `/v1/tokens`, are plain `fetch` calls.
- It also runs tools in your app. See [Tools in your app](/build/tool-workers/).

## Details

- `POST .../cancel` stops the running turn. `DELETE .../conversation` clears it.
  `DELETE /v1/agents/$AGENT` removes the agent.
- `POST .../stop` puts an agent to sleep. `POST .../spawn` starts it again.
- An agent a file declares can't be removed over HTTP: remove the file and reload.
- `GET /v1/interrupts` lists every call waiting on a person.
- Triggers are at `/v1/agents/$AGENT/triggers/{name}`. See [Trigger an agent](/build/triggers/).
- Every answer has a `request-id` header.

### Errors

An error answers `{"error": {"type": ..., "message": ...}}`:

| Status | `type` | |
| --- | --- | --- |
| 400 | `invalid_request` | the request doesn't read |
| 401 | `unauthorized` | no token, or one that's revoked or expired |
| 403 | `forbidden` | the token reaches it, and may not do this |
| 404 | `not_found` | no such thing, or one the token doesn't reach |
| 409 | `conflict` | not waiting on that call, busy, or declared by a file |
| 503 | `unavailable` | the store can't answer now |
