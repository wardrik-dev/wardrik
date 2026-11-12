---
title: A support agent per customer
description: "One agent per customer, with tools from your app. Each agent can access only its customer's orders, and large refunds need approval."
sidebar:
  order: 2
---

Create an agent per customer and connect it to your app’s order and refund functions. Refunds
up to $50 run automatically; larger refunds require approval in Slack. Your tools use the calling
agent’s ID to restrict access to that customer’s orders. Idle agent processes stop and restart
when a message arrives.

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
    domains: {shop.com: shop}

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

- `trusted_workers: true` marks your app's results as trusted, so a lookup doesn't make every
  refund need approval.
- The `support` policy applies to every agent in the org, regardless of its definition.

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

// Wardrik passes the calling agent's ID. Your app maps it to a customer.
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

// The daemon creates the agent and returns its ID. Store the ID on the customer.
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
npm install @wardrik/sdk@0.1.0-rc.5 zod
```

Run your app and ask a customer's agent for a $20 refund. It runs. Ask for $200, and the call is
posted to `#support` with **Approve** and **Deny**.

## How it works

- One agent per customer, each with its own history. Idle agents stop until the next message.
- Tools receive the calling agent's ID from Wardrik, not from the model's arguments. Your application must
  enforce the customer mapping on every order lookup and refund.
- Refund limits are in the org policy. No agent definition can bypass them.
- See [Tools in your app](/build/tool-workers/).
