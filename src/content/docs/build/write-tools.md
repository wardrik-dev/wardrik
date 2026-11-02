---
title: Write tools
description: "Define a tool's arguments, result and errors, answer each agent with its own data, report cost, and make a call safe to run twice."
sidebar:
  order: 3.2
---

```ts
wardrik.tool({
  name: "find_order",
  description: "The order a Stripe payment intent paid for: items, address, dates.",
  input: z.object({ payment_intent: z.string().describe("As pi_123") }),
  readOnly: true,
  run: ({ payment_intent }) => orders.byPaymentIntent(payment_intent),
});
```

| Key | |
| --- | --- |
| `name` | 1 to 55 letters, digits, `_` and `-` |
| `description` | what the model is told the tool does |
| `title` | a short name for people |
| `input` | a `zod` object schema for its arguments; `.describe()` tells the model what goes there |
| `readOnly` | it changes nothing, so it never waits on a person |
| `idempotent` | running a call twice is safe |
| `run` | the function, given the arguments and `{ agent, run, idempotencyKey, signal, cost }` |

- An agent gets the tools with `workers/*` in its `tools`. The model sees `workers__find_order`.
- A policy names it as `workers/find_order`.

## Results and errors

Return an object or a string. Return only what the model needs: it reads every word.

Throw to fail the call. Say what went wrong in words the model can act on:

```ts
run: async ({ order_id }) => {
  const order = await orders.find(order_id);
  if (!order) throw new Error(`No order ${order_id}. Order IDs look like ord_1234.`);
  return { id: order.id, status: order.status };
},
```

## Whose call it is

`agent.key` is the calling agent's ID, set by Wardrik, never by the model. Use it to scope data:

```ts
run: (_args, { agent }) => db.orders.where({ agent: agent?.key }),
```

## What a call cost

Report what a paid API cost, in US dollars. The agent's [budget](/concepts/budgets/) counts it:

```ts
run: async ({ email }, { cost }) => {
  const found = await enrich.lookup(email);
  cost(0.01);
  return found;
},
```

## Running a call twice

`idempotencyKey` is the same each time a call runs. Pass it on, and mark the tool `idempotent`:

```ts
wardrik.tool({
  name: "refund_order",
  description: "Refund an order in full.",
  input: z.object({ orderId: z.string() }),
  idempotent: true,
  run: ({ orderId }, { idempotencyKey }) =>
    stripe.refunds.create({ payment_intent: orderId }, { idempotencyKey }),
});
```

- A call cut off by a dropped connection runs again only if the tool is `idempotent` or
  `readOnly`. Otherwise it waits for a person. See [Calls in doubt](/build/host-tools/#calls-in-doubt).
- For an API with no key, keep what each key did, and answer with that when it comes again.

## Details

- `signal` aborts when the call is stopped or times out. Pass it to `fetch`.
- A call may take 60 seconds.
- `run` in the context is the run's ID, as its events carry it.
- `cost` called twice adds up.
- A tool with a bad name, or an `input` that isn't an object schema, is left out.
