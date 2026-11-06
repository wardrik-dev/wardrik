---
title: Write tools
description: "Define a tool's arguments, result and errors, scope data by agent, report cost, and make calls safe to retry."
sidebar:
  order: 3.2
---

Register a function with `wardrik.tool()`. Define its arguments with Zod and return the data the
model needs. These examples assume an initialized SDK client and your application’s data helpers.

```ts
wardrik.tool({
  name: "find_order",
  description: "Find the order associated with a Stripe payment intent, including items, address, and dates.",
  input: z.object({ payment_intent: z.string().describe("Stripe payment intent ID, such as pi_123") }),
  readOnly: true,
  run: ({ payment_intent }) => orders.byPaymentIntent(payment_intent),
});
```

| Key | Description |
| --- | --- |
| `name` | 1 to 55 letters, digits, `_` and `-` |
| `description` | the description sent to the model |
| `title` | a display name |
| `input` | a `zod` object schema for the arguments; `.describe()` documents a field for the model |
| `readOnly` | marks the tool as read-only, removing the default approval requirement; explicit policy rules still apply |
| `idempotent` | safe to retry with the same idempotency key without repeating its effects |
| `run` | the function; receives the arguments and `{ agent, run, idempotencyKey, signal, cost }` |

- Add `workers/*` to an agent's `tools`. The model sees `workers__find_order`.
- In a policy, it's `workers/find_order`.

## Results and errors

Return an object or a string. Return only what the model needs, since every token counts.

Throw an error to fail the call. Include enough context for the model to correct its request:

```ts
run: async ({ order_id }) => {
  const order = await orders.find(order_id);
  if (!order) throw new Error(`No order ${order_id}. Order IDs look like ord_1234.`);
  return { id: order.id, status: order.status };
},
```

## The calling agent

`agent` is the calling agent's ID. Wardrik sets it, not the model. Use it to scope data:

```ts
run: (_args, { agent }) => db.orders.where({ agent }),
```

## Cost

Call `cost` with a paid API's cost in US dollars. It's added to the agent's
[budget](/concepts/budgets/):

```ts
run: async ({ email }, { cost }) => {
  const found = await enrich.lookup(email);
  cost(0.01);
  return found;
},
```

## Retries

`idempotencyKey` is the same on every attempt of a call. Pass it to the API, and mark the tool
`idempotent`:

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

- Only `idempotent` or `readOnly` tools are retried. See [Durable runs](/concepts/agents/#durable-runs).
- For an API without idempotency keys, store each key's result and return it on a repeat.

## Details

- `signal` aborts when the call is stopped or times out. Pass it to `fetch`.
- A call times out after 60 seconds.
- `run` in the context is the turn's ID, the same as in its events.
- Calling `cost` twice adds both amounts.
- A tool with an invalid name, or an `input` that isn't an object schema, is skipped.
