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

A token comes from the daemon: `wardrik token create NAME --scope acme/
--unlimited`. It reaches the agents whose keys start with its scope, and takes
the actions it was made with, all of them unless `--can` names fewer. A token
that can define agents is made with `--policy NAME`, a policy the daemon holds
that every agent it defines is held to, or with `--unlimited`. An action it was not
granted throws a `WardrikError` of type `forbidden`, and a revoked token closes
its streams and workers.

## Agents

An agent's key is `org/name`, or `org/@user/name` for one that works for a user.

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

await agent.schedule("sweep", { every: "*/30 * * * *", prompt: "Check the queue." });
```

`ask` sends a message and gives the events of the run that answers it, until
that run completes, fails or is cancelled. `send` only queues the message.
`snapshot`, `page`, `reject`, `cancel`, `unschedule` and `delete` are one
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
const events = agent.events({ after: 41 });

for await (const event of events) {
  // …
}
```

A stream reconnects after any drop, a `kill -9` of the node included, and
resumes after the last durable event it gave, `events.sequence`. Left without
`after`, it starts after the last event the agent had written. Live events
(text and reasoning deltas, tool progress) are not sent again after a
reconnect; `wardrik.message.completed` carries the whole text. When the log no
longer holds what comes after the cursor, the stream throws a `WardrikError` of
type `gap`: read `agent.snapshot()` and follow from its `sequence`.

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

`idempotencyKey` is the same each time the daemon runs one call. A call the
daemon cannot tell finished, because its agent was lost while the call was
running, runs again under the same key where every worker in reach marks the
tool `idempotent` or `readOnly`, and waits for a person otherwise. A tool that
is not `readOnly` is gated: a call to it waits on a person unless the agent's
policy allows it by name.

`run` answers an object as the call's result and a string as text. A thrown
error is a failed call the model is told about. `signal` aborts when the
daemon stops waiting for the call.

`examples/refund.ts` runs a worker and an agent together.

## Errors

A request the API refuses throws a `WardrikError`, with the answer's `status`,
its `type` (`not_found`, `conflict`, `gap` and so on), and its `requestId`.

## Types

`src/protocol.ts` is generated from the protocol's JSON Schemas in
`priv/protocol/v1`. After changing a schema, run `npm run generate`;
`npm run check` fails while it is out of date.

```sh
npm ci
npm run check   # generated types, type check, tests
npm run build   # dist/
```
