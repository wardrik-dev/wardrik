---
title: A support agent per customer
description: "One agent for every customer, with your app's tools: it sees only that customer's orders, and big refunds wait."
sidebar:
  order: 2
---

Give every customer an agent of their own. It answers in your app, remembers their history, and
looks up their orders with tools in your own code. It can refund small amounts on its own; bigger
refunds wait for your team in Slack. No customer's agent can reach another customer's orders,
whatever the customer types.

Thousands of these cost almost nothing: an agent nobody is talking to sleeps until the next message.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key;
- your app, offering tools and talking to agents with the
  [TypeScript SDK](/build/tool-workers/);
- a [Slack app](/channels/slack/#a-slack-app) and a channel for refunds, here `#support`.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
org: shop

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}

notify:
  support:
    channel: slack
    room: "#support"
    approvers: ["@maria", "@sam"]
```

### The policy

```yaml title="~/.config/wardrik/policies/support.yaml"
allow:
  - workers/list_orders
  - workers/order_status
  - workers/refund_order(amount <= 50)
ask:
  workers/refund_order(amount > 50): A refund over $50.
budget:
  usd: 0.50
  per: day
  on_exhausted: deny
```

- Refunds up to $50 run. Anything more waits for someone in `#support`.
- Each customer's agent may spend 50 cents a day on its model, then stops for the day.

### Your app's tools

```ts title="support.ts"
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";

const wardrik = new Wardrik({ name: "support" });

wardrik.tool({
  name: "list_orders",
  description: "List the customer's orders.",
  input: z.object({}),
  readOnly: true,
  run: (_args, { agent }) => db.orders.where({ customer: agent?.user }),
});

wardrik.tool({
  name: "order_status",
  description: "Where one of the customer's orders is.",
  input: z.object({ order_id: z.string() }),
  readOnly: true,
  run: ({ order_id }, { agent }) => db.orders.find({ id: order_id, customer: agent?.user }),
});

wardrik.tool({
  name: "refund_order",
  description: "Refund part or all of one of the customer's orders, in US dollars.",
  input: z.object({ order_id: z.string(), amount: z.number().positive() }),
  idempotent: true,
  run: ({ order_id, amount }, { agent, idempotencyKey }) =>
    payments.refund({ order_id, customer: agent?.user, amount }, { idempotencyKey }),
});

await wardrik.work();
```

- `agent.user` is the customer the agent works for, taken from its key, never from what the model
  wrote. See [Whose call it is](/build/write-tools/#whose-call-it-is).
- `refund_order` changes something, so it's [gated](/concepts/rules/#gated-tools): only the policy's
  `allow` lets small refunds through.

### Talking to a customer's agent

When a customer writes in, your app makes sure their agent exists, then asks it:

```ts title="chat.ts"
export async function answer(customerId: string, text: string, reply: (delta: string) => void) {
  const agent = await wardrik.agents.put(`shop/@${customerId}/support`, {
    description: "Support for one customer.",
    instructions: "You help this customer with their orders. Be brief and kind.",
    tools: ["workers/*"],
    policy: "support",
    notify: { to: ["support"], on: ["parked"] },
  });

  for await (const event of agent.ask(text)) {
    if (event.type === "wardrik.message.delta") reply(event.data.delta);
  }
}
```

Make the app's token so it can define these agents only under the policy, and serve them tools:

```sh
wardrik token create shop --resource 'shop/*' --role reader,messenger,definer,worker --policy support
```

`--policy` is the token's policy: no agent it defines can do more than `support.yaml` allows. See
[Tokens](/run/tokens/).

## Try it

Run `support.ts`, then call `answer("cus_123", "Where's my order?", process.stdout.write)`. Ask it
for a $20 refund and it's done. Ask for $200 and it says a person will look; the request waits in
`#support` with **Approve** and **Deny**.

## What it shows

- **One agent per customer**, each with its own memory, keyed `shop/@<customer>/support`.
- **Thousands, asleep.** Idle agents sleep and wake on the next message. See
  [Lifecycle](/concepts/agent-lifecycle/#sleeping).
- **Data isolation in code.** Tools answer for the agent's own customer, from its key.
- **Refund limits as policy**, with big ones waiting for a person.
- **A token's policy.** Your app can't define a looser agent than the policy allows.

## Details

### Why the key matters

A token reaches agents by resource pattern, `shop/*`, and a tool learns the agent from its key. A customer can tell
their agent to look up someone else's order, and the tool still answers only for them.

### Taking it further

- Hand a conversation to a person: deny a tool and have the agent post a summary to `#support`.
- Use Stripe for refunds through its MCP server instead of your own tool; gate its
  `stripe_api_write` the same way.
