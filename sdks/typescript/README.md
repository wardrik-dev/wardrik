# Wardrik SDK for TypeScript

Drives Wardrik agents over the daemon's HTTP API, and offers them tools that run
in your own process, as the npm package `@wardrik/sdk`, which is not
published yet.

Node 22.18 or later, Bun or Deno. `zod` 4 is a peer dependency, for tool
inputs.

## Connecting

```ts
import { Wardrik } from "@wardrik/sdk";

const wardrik = new Wardrik(); // WARDRIK_URL, else http://127.0.0.1:4747; WARDRIK_TOKEN
```

A token comes from the daemon, `wardrik token create NAME --resource 'acme/agent/*' --role
reader,messenger`, or from `wardrik.tokens.create` with a token owning `*`. It
acts for whoever made it, on the resources its patterns cover, holding the roles
it was made with: each a named set of actions, from `reader` to `owner`.
An action it does not allow throws a `WardrikError` of type `forbidden`, an
expired token one of type `unauthorized`, and a revoked token closes its
streams and workers.

## Agents

An agent's key is `org/name`, or `org/@user/name` for one that works for a user.
A thread a channel starts for a conversation, as `acme/triage/C1-1696.1234`, has
no key: `wardrik.agents.list()` lists it and its events are read, but no `Agent`
reaches it.

```ts
const agent = await wardrik.agents.put("acme/triage", {
  model: "anthropic:claude-sonnet-5",
  instructions: "You watch the incident queue.",
  tools: ["linear/*", "workers/*"],
});

for await (const event of agent.ask("What's on fire?")) {
  if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);

  if (event.type === "wardrik.run.interrupted") {
    for (const interrupt of event.data.interrupts) await agent.approve(interrupt.id);
  }
}

await agent.setTrigger("sweep", { every: "*/30 * * * *", prompt: "Check the queue." });
```

`ask` sends a message and gives the events of the run that answers it, until
that run completes, fails or is cancelled. `send` only queues the message.
`snapshot`, `page`, `reject`, `cancel`, `clear`, `removeTrigger` and `delete` are one
request each, and `wardrik.agents.list()` lists what the token reaches.

An interrupt with reason `authorization` waits for a person to connect an
account. No event carries the link: `agent.authorization(interrupt.id)`
answers it, `{ url, code? }`, to a token that may decide the agent's calls.
The call carries on by itself once the person has connected.

## Events

Every event is a CloudEvent whose `type` is `wardrik.<noun>.<verb>`, and
`WardrikEvent` is a union over `type`, so a check of `event.type` narrows
`event.data`.

```ts
const events = agent.events({ after: saved });

for await (const event of events) {
  // …
}
```

A stream reconnects after any drop, a `kill -9` of the node included, and
resumes after the last event it gave that moved its cursor, `events.cursor`:
an opaque string, where the reader has got to in each agent's log, which
`after` takes back. A snapshot's `cursor` and a sent message's are one too.
Left without `after`, an agent's stream starts where its log stood when it
opened. Live events (text and reasoning deltas, tool progress, and
`wardrik.activity.changed`, what the agent is doing now) move no cursor and
are not sent again after a reconnect; `wardrik.message.completed` carries
the whole text, and `agent.snapshot()` what the agent is doing. Where a log
was trimmed past the cursor, a `wardrik.events.dropped` says so, and the log
is read on from the oldest event it holds.

`wardrik.events` reads many agents at once, by pattern:

```ts
const events = wardrik.events({
  resources: ["acme/agent/*"],
  types: ["wardrik.run.completed"],
  after: saved,
  follow: true,
});

for await (const event of events) await save(event, events.cursor);
```

A `wardrik.events.dropped` comes whatever `types` names, so a gap never
passes unseen. Without `follow`, it reads what is kept after `after`, a page
at a time, and ends. The server keeps no reader's place, so keep `cursor` with what you
read, and read on from it.

## Owners

The accounts an owner's agents act with, and the MCP servers they add, are
named by their owner: an org, `acme`, or a person, `acme/@jon`.

```ts
const linear = await wardrik.connections.connect("acme/@jon", "linear");
if (!linear.connected) console.log("Authorize at", linear.authorization?.url);

await wardrik.servers.add("acme", {
  name: "crm",
  url: "https://mcp.crm.example/mcp",
  auth: { secret: { name: "crm-key" } },
});
```

## Tools

```ts
import { z } from "zod";

wardrik.tool({
  name: "refund_order",
  description: "Refund an order in full.",
  input: z.object({ orderId: z.string() }),
  idempotent: true,
  run: ({ orderId }, { idempotencyKey }) =>
    stripe.refunds.create({ payment_intent: orderId }, { idempotencyKey }),
});

await wardrik.work();
```

`work` holds a WebSocket to the daemon open and answers calls over it, as an
MCP server, until its `signal` aborts. The daemon offers the tools, as
`workers__<name>`, to every agent the token reaches whose tools name
`workers/*`.

`agent` is the agent a call is made for, `{ key, org, user?, name }`, which
the daemon names from the key the worker's token was checked against, never
from what the model sent: a worker serving an agent for each customer answers
each with what is theirs. `run` is the run the call is part of.

`idempotencyKey` is the same each time the daemon runs one call. A call the
daemon cannot tell finished, because its agent or its worker was lost while
the call was running, or it answered late, runs again under the same key where
every worker in reach marks the tool `idempotent` or `readOnly`, and waits for
a person otherwise. A tool that is not `readOnly` is gated: a call to it waits
on a person unless the agent's policy allows it by name. A tool is bound to
the token that offers it: workers under another token offering the same name
to the same agent are refused.

`run` answers an object as the call's result and a string as text. A thrown
error is a failed call the model is told about. `signal` aborts when the
daemon stops waiting for the call, or stops it.

`examples/refund.ts` runs a worker and an agent together.

## Errors

A request the API refuses throws a `WardrikError`, with the answer's `status`,
its `type` (`not_found`, `conflict`, `gap` and so on), and its `requestId`.

## Types

`src/protocol.ts` is generated from the protocol's JSON Schemas in
`packages/wardrik_protocol/priv/v1`. After changing a schema, run `npm run generate`;
`npm run check` fails while it is out of date.

```sh
npm ci
npm run check   # generated types, type check, tests
npm run build   # dist/
```
