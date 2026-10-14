---
title: Use the HTTP API
description: Define an agent, ask it something, follow its answer and decide what it waits on, over HTTP or with the TypeScript SDK.
sidebar:
  order: 4
---

The daemon serves a JSON API on `127.0.0.1:4747`. It defines and removes agents, sends them
messages, streams what they do, and decides the calls they wait on. This guide walks through one
agent's life; [HTTP API](/reference/http-api/) lists every route and resource.

## A token

Every request presents a token. Make one with what it needs to reach, and no more:

```sh
wardrik token create app --scope acme/ --policy careful
```

The token is printed once. Send it as `authorization: Bearer wardrik_...`:

```sh
export TOKEN=wardrik_...
curl -s -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents
```

`--scope acme/` reaches acme's own agents, and an agent outside it is answered as one that does not
exist. A user's agents are reached by a scope naming them, `acme/@jon/`, or by `acme/*`, the whole
tenant: acme's agents and every one of its users'. A token that can define agents holds them to a
policy, here `careful`, ahead of their own. See [Tokens](/run/security/#tokens).

## Define an agent

`PUT` a definition at the agent's key, which is its path: `acme/triage` for an org's own agent, or
`acme/@jon/triage` for one that works for a user. Over the HTTP API a key is always written in
full, with its org:

```sh
curl -s -X PUT -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage \
  -d '{
    "description": "Watches the incident queue.",
    "instructions": "You watch the incident queue, and say what needs an engineer.",
    "model": "anthropic:claude-sonnet-5",
    "tools": ["linear/*"],
    "policy": {"ask": ["linear/create_*"]}
  }'
```

It answers `201` and the agent's snapshot, and starts the agent. Putting it again answers `200` and
gives the running agent what the definition says now, keeping its conversation.

A definition takes `description`, `instructions` for the system prompt, `model`, `tools`,
`workspace`, `context`, `policy`, `timeout`, `max_iterations`, `retries`, `compaction`, `triggers`
and [`notify`](/build/notices/), as an [agent file](/reference/agent-files/) does. It names tools and policies the
daemon ships or configures, never a module, shares only the trees its token's scope covers, and
cannot trust outside content. A key an agent file declares belongs to the file, and is refused with
`409`.

## Ask it something

`POST` a message. It answers `202` at once, with the message's id; the agent answers in its own
time:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage/messages \
  -d '{"id": "b7c1d0e2-...", "content": "What is on fire?"}'
```

`id` is optional. A message sent again with the same id is taken once, so a client that is not sure
its request arrived can send it again.

### Follow the answer

The answer arrives as events. Stream them, and read the reply as `message.delta` events while it is
written, then `message.completed` and `run.completed`:

```sh
curl -N -H "authorization: Bearer $TOKEN" -H "accept: text/event-stream" \
  http://127.0.0.1:4747/v1/agents/acme/triage/events
```

Open the stream before sending the message, or read the agent's snapshot first and follow from its
`sequence` with `Last-Event-ID`, so nothing is missed. See
[The event stream](/concepts/events/#following-over-http).

`GET /v1/agents/acme/triage` answers the agent's snapshot: its status, what it is waiting on, its
messages, and the `sequence` it was taken at.

## Decide what it waits on

A call that waits on a person arrives as `run.interrupted`, whose `interrupts` each have an `id`, a
`reason`, the `message` a person is asked, and the `labels` of what the turn had read first, such
as `["outside"]` for content from outside. With a token that can `decide`:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage/decisions \
  -d '{"decisions": [{"id": "call_1", "decision": "approve", "note": "Label it for the next sprint."}]}'

curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage/decisions \
  -d '{"decisions": [{"id": "call_1", "decision": "reject", "reason": "Not on a Friday."}]}'
```

Several calls the agent waits on can be decided in one request, each its own entry in `decisions`.

A `note` with an approval is what the model reads beside the call's answer; it never changes the
call, which runs as the model wrote it. A `reason` with a rejection is what it reads in place of
the answer.

An interrupt with the reason `authorization` waits on a person to connect an account.
`GET .../interrupts/{id}/authorization` answers where, as `{"url": ..., "code": ...}`, and the call
carries on by itself once they have. See [Connect accounts](/build/accounts/).

## Connect accounts

A token made `--for` a person connects their accounts before any agent asks for one:

```sh
curl -s -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/connections
# {"connections": [{"provider": "github", "held_by": "person"}, {"provider": "linear"}]}

curl -s -X POST -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/connections/linear
# {"provider": "linear", "connected": false, "authorization": {"url": "https://…"}}

curl -s -X DELETE -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/connections/linear
```

`held_by` is `person`, `org` or `deployment`, whichever a call of theirs would use, and absent where
nobody holds it. The person is the user the token's scope names, else the one it was made `--for`;
a token for no person, or one that may `define` under the org, asks with `?owner=org` for the org's.
Listing needs `read`, and connecting and forgetting `define`. Connecting parks nothing: the account
is held once the person has authorized at the link.

## Stop it, clear it, and remove it

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents/acme/triage/cancel
curl -s -X DELETE -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents/acme/triage/conversation
curl -s -X DELETE -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents/acme/triage
```

`cancel` stops the running turn, drops the messages waiting behind it, and abandons one waiting on a
person; the agent answers the next message as usual, and one taking no turn is left as it is. It
answers the agents it stopped, as `{"cancelled": ["acme/triage"]}`. `DELETE .../conversation`
empties the conversation, and with it the mark of
[content from outside](/concepts/outside-content/) it held, answering `409` while a turn
runs or waits on a person. `DELETE` stops the agent and removes its conversation and triggers, and
answers `{"forgotten": ["acme/triage"], "kept": [], "failed": []}`.

Every agent under a prefix is stopped or removed at once, with the prefix named:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/agents/cancel?prefix=acme/"
curl -s -X DELETE -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/agents?prefix=acme/&plan=true"
```

`?plan=true` answers what a change would do, and does nothing: here, the agents it would remove,
and those it keeps, such as one an agent file declares, with why. Any route that changes something
takes it. `GET /v1/agents?prefix=acme/` lists the agents under a prefix, and `GET /v1/interrupts`
the calls they wait on a person for.

`POST .../stop` puts an agent to sleep with its conversation, and `POST .../spawn` starts it again,
or starts one the server defines, or has the server define a new one as `wardrik agent spawn` does.
Where an agent runs is the deployment's to say: `POST .../move` with `{"node": "wardrik@box2"}`,
or `spawn` with a node, takes a token over every agent.

A definition's `triggers` lists the agent's triggers, and one is put or removed at
`/triggers/{name}`; see [Trigger an agent](/build/triggers/#over-http).

A service's webhooks reach a `webhook` trigger at `POST /v1/hooks/{key}/{name}`, with no token: the
trigger checks each request's signature instead. See
[Receiving a webhook](/build/triggers/#receiving-a-webhook).

## The deployment

A token over every agent, made with `wardrik token create NAME --all`, also reaches the deployment
itself:

```sh
curl -s -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/deployment/nodes
# {"nodes": [{"name": "wardrik@box1", "agents": 12}], "asleep": 40}
curl -s -X POST -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/deployment/reload
curl -s -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/deployment/audit?starting_after=120"
```

`nodes` counts the agents running on each node, and those asleep on none. `reload` reads the agent
and policy files again on every node, as `wardrik reload` does. `audit` pages what people changed,
each change a CloudEvent naming who made it, as `wardrik audit` prints them. Tokens are made from a
shell on the server alone, never over the API.

## Errors

An error answers with its status and a body saying what went wrong:

```json
{"error": {"type": "not_found", "message": "No agent runs under acme/triage."}}
```

| Status | `type` | |
| --- | --- | --- |
| 400 | `invalid_request` | the request does not read |
| 401 | `unauthorized` | no token, or one that does not work |
| 403 | `forbidden` | the token may not do this |
| 404 | `not_found` | no such agent, or one outside the token's scope |
| 409 | `conflict` | the agent is not waiting on that call, or a file declares it |
| 410 | `gap` | an event stream position older than what is kept |
| 503 | `unavailable` | the store cannot answer just now, as in a cluster without a quorum |

Every answer has a `request-id` header, which the daemon's log names too.

## With the TypeScript SDK

The SDK does the same, and follows the stream for you, reconnecting and resuming where it left off:

```ts
import { Wardrik } from "@wardrik/sdk";

const wardrik = new Wardrik(); // WARDRIK_URL, else http://127.0.0.1:4747; WARDRIK_TOKEN

const agent = await wardrik.agents.put("acme/triage", {
  model: "anthropic:claude-sonnet-5",
  instructions: "You watch the incident queue.",
  tools: ["linear/*"],
});

for await (const event of agent.ask("What is on fire?")) {
  if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);

  if (event.type === "wardrik.run.interrupted") {
    for (const interrupt of event.data.interrupts) await agent.approve(interrupt.id);
  }
}
```

`ask` gives the events of the turn that answers the message, until it completes, fails or is
cancelled. `wardrik.connections` lists, connects and forgets accounts, with `{owner: "org"}` for the
org's, and `wardrik.deployment` lists the nodes, reloads and pages the audit. A request the API refuses throws a `WardrikError` with its `status`, `type` and
`requestId`. The SDK also runs tools in your app; see [Tools in your app](/build/tool-workers/).
