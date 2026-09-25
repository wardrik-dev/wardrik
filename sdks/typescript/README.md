# Tars SDK for TypeScript

Drives Tars agents over the daemon's HTTP API, and offers them tools that run
in your own process. `@tars/sdk` is a working name; the package is not
published yet.

Node 22.18 or later, Bun or Deno. `zod` 4 is a peer dependency, for tool
inputs.

## Connecting

```ts
import { Tars } from "@tars/sdk";

const tars = new Tars(); // TARS_URL, else http://127.0.0.1:4747; TARS_TOKEN
```

A token comes from the daemon: `tars token create NAME --scope acme/`. It
reaches the agents whose keys start with its scope.

## Agents

An agent's key is `org/user/name`, with `_` for none.

```ts
const agent = await tars.agents.put("acme/_/triage", {
  model: "anthropic:claude-sonnet-5",
  instructions: "You watch the incident queue.",
  tools: ["linear/*", "workers/*"],
});

for await (const event of agent.ask("What's on fire?")) {
  if (event.type === "tars.message.delta") process.stdout.write(event.data.delta);

  if (event.type === "tars.run.interrupted") {
    for (const interrupt of event.data.interrupts) await agent.approve(interrupt.id);
  }
}

await agent.schedule("sweep", { every: "*/30 * * * *", prompt: "Check the queue." });
```

`ask` sends a message and gives the events of the run that answers it, until
that run completes, fails or is cancelled. `send` only queues the message.
`snapshot`, `page`, `reject`, `cancel`, `unschedule` and `delete` are one
request each, and `tars.agents.list()` lists what the token reaches.

## Events

Every event is a CloudEvent whose `type` is `tars.<noun>.<verb>`, and
`TarsEvent` is a union over `type`, so a check of `event.type` narrows
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
reconnect; `tars.message.completed` carries the whole text. When the log no
longer holds what comes after the cursor, the stream throws a `TarsError` of
type `gap`: read `agent.snapshot()` and follow from its `sequence`.

## Tools

```ts
import { z } from "zod";

tars.tool({
  name: "refund_order",
  description: "Refund an order in full.",
  input: z.object({ orderId: z.string() }),
  idempotent: true,
  run: ({ orderId }, { idempotencyKey }) =>
    stripe.refunds.create({ payment_intent: orderId }, { idempotencyKey }),
});

await tars.work();
```

`work` holds a WebSocket to the daemon open and answers calls over it, as an
MCP server, until its `signal` aborts. The daemon offers the tools, as
`workers__<name>`, to every agent the token reaches whose tools name
`workers/*`.

`idempotencyKey` is the same each time the daemon runs one call. A call the
daemon cannot tell finished, because its agent was lost while the call was
running, runs again under the same key where every worker in reach marks the
tool `idempotent` or `readOnly`, and waits for a person otherwise.

`run` answers an object as the call's result and a string as text. A thrown
error is a failed call the model is told about. `signal` aborts when the
daemon stops waiting for the call.

`examples/refund.ts` runs a worker and an agent together.

## Errors

A request the API refuses throws a `TarsError`, with the answer's `status`,
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
