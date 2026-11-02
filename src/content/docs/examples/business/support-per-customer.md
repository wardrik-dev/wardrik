---
title: A support agent per customer
description: "One agent for every customer, with your app's tools: it sees only that customer's orders, and big refunds wait."
sidebar:
  order: 2
---

Every customer gets an agent of their own. It answers in your app and looks up their orders with
tools in your code. Refunds up to $50 run; bigger ones wait for your team in Slack. No customer's
agent can reach another customer's orders. An agent nobody is talking to sleeps, so thousands cost
almost nothing.

## The files

```yaml title="~/.config/wardrik/config.yaml"
org: shop

http:
  trusted_workers: true

orgs:
  shop: {policy: support}

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    members: {U024BE7LH: user:shop/@maria, U0G9QF9C6: user:shop/@sam}

notify:
  targets:
    support: {channel: slack, room: "#support"}

roles:
  app:
    rules: [{verbs: [create, define, ask, read, events, serve], kinds: [agent]}]
  support:
    rules: [{verbs: [read, events, decide], kinds: [agent]}]
bindings:
  - {org: shop, role: app, subjects: [user:shop/@app]}
  - {org: shop, role: support, subjects: [user:shop/@maria, user:shop/@sam]}
```

- `trusted_workers: true` treats your app's answers as your own, so a lookup doesn't make every
  refund wait.
- The `support` policy holds every agent in the org, whatever your app defines.

```yaml title="~/.config/wardrik/policies/support.yaml"
allow:
  - workers/list_orders
  - workers/refund_order(amount <= 50)
ask:
  workers/refund_order(amount > 50): A refund over $50.
```

```ts title="support.ts"
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";
import { db, payments } from "./app.ts"; // your app's own

export const wardrik = new Wardrik({ name: "support" });

// Wardrik says which agent is calling. Your app knows whose agent that is.
const customerOf = (agent?: string) => db.customers.findBy({ agentId: agent });

wardrik.tool({
  name: "list_orders",
  description: "List the customer's orders.",
  input: z.object({}),
  readOnly: true,
  run: async (_args, { agent }) => db.orders.where({ customer: (await customerOf(agent)).id }),
});

wardrik.tool({
  name: "refund_order",
  description: "Refund part or all of one of the customer's orders, in US dollars.",
  input: z.object({ order_id: z.string(), amount: z.number().positive() }),
  idempotent: true,
  run: async ({ order_id, amount }, { agent, idempotencyKey }) => {
    const customer = (await customerOf(agent)).id;
    return payments.refund({ order_id, customer, amount }, { idempotencyKey });
  },
});

void wardrik.work();
```

```ts title="chat.ts"
import { wardrik } from "./support.ts";
import { db } from "./app.ts";

// The daemon makes an agent and gives it an ID. Keep the ID with the customer.
async function agentFor(customer: { id: string; agentId?: string }): Promise<string> {
  if (customer.agentId) return customer.agentId;

  const response = await fetch(`${process.env.WARDRIK_URL}/v1/owners/shop/agents`, {
    method: "POST",
    headers: { authorization: `Bearer ${process.env.WARDRIK_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({
      name: customer.id,
      instructions: "You help this customer with their orders. Be brief and kind.",
      tools: ["workers/*"],
      notify: { to: ["support"], on: ["parked"] },
    }),
  });
  const { id } = await response.json();
  await db.customers.update(customer.id, { agentId: id });
  return id;
}

export async function answer(customer: { id: string; agentId?: string }, text: string) {
  const agent = wardrik.agent(await agentFor(customer));
  for await (const event of agent.stream(text)) {
    if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);
  }
}
```

## Try it

```sh
systemctl --user restart wardrik
wardrik token create shop-app --subject user:shop/@app     # your app's WARDRIK_TOKEN
npm install @wardrik/sdk@0.1.0-rc.2 zod
```

Run your app and ask a customer's agent for a $20 refund: it's done. Ask for $200 and it says a
person will look. The call waits in `#support` with **Approve** and **Deny**.

## What it shows

- One agent per customer, each with its own history. Idle agents sleep until the next message.
- A tool learns which agent called from Wardrik, never from what the model wrote. A customer can't
  talk their agent into another customer's orders.
- Refund limits are policy. Your app can't define an agent that gets around them.
- See [Tools in your app](/build/tool-workers/).
