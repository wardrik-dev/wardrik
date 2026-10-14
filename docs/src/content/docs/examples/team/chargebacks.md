---
title: Win chargebacks
description: "A Stripe webhook starts it on each new dispute; it builds the evidence and waits for your approval to submit."
sidebar:
  order: 2
---

Every chargeback has a deadline and a pile of evidence to gather. This agent starts the moment
Stripe opens a dispute: it pulls the order, the shipment and the customer's messages from your own
app, writes the evidence, and proposes the submission in Slack. You read it, approve it, and it's
filed.

Reading runs alone. Submitting to Stripe waits for a person. Each dispute is its own turn, with its
own budget and a record of who approved what.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key, and a
  [public address](/run/public-address/) Stripe can reach;
- a Stripe [Agent API key](https://docs.stripe.com/mcp) for Stripe's MCP server;
- an app of your own offering your order, shipping and support data, with the
  [TypeScript SDK](/build/tool-workers/);
- a [Slack app](/channels/slack/#a-slack-app) and a channel for it, here `#disputes`.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
org: acme
base_url: https://agents.acme.example

mcp:
  stripe:
    url: https://mcp.stripe.com
    credential: STRIPE_AGENT_KEY

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}

notify:
  disputes:
    channel: slack
    room: "#disputes"
    approvers: ["@maria", "@sam"]
```

- Stripe's MCP server reads anything with `stripe_api_read` and writes with `stripe_api_write`. Only
  writes are [gated](/concepts/rules/#gated-tools).
- `credential` sends acme's key as a bearer token. `base_url` is where Stripe sends webhooks.

Seal acme's secrets and restart:

```sh
wardrik vault put STRIPE_AGENT_KEY --org acme
wardrik vault put STRIPE_HOOK_SECRET --org acme
systemctl --user restart wardrik
```

`STRIPE_HOOK_SECRET` is any long random string. Stripe sends it back at the end of the webhook's URL.

### Your shop's tools

Your app answers from your own data. Here `shop` stands for your database and helpdesk:

```ts title="disputes.ts"
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";

const wardrik = new Wardrik({ name: "disputes" });

wardrik.tool({
  name: "find_order",
  description: "The order a Stripe payment intent paid for: items, address, dates.",
  input: z.object({ payment_intent: z.string() }),
  readOnly: true,
  run: ({ payment_intent }) => shop.orders.byPaymentIntent(payment_intent),
});

wardrik.tool({
  name: "shipment",
  description: "How an order shipped: carrier, tracking number, and the delivery scan.",
  input: z.object({ order_id: z.string() }),
  readOnly: true,
  run: ({ order_id }) => shop.shipments.forOrder(order_id),
});

wardrik.tool({
  name: "customer_messages",
  description: "Every message between us and the customer about an order, oldest first.",
  input: z.object({ order_id: z.string() }),
  readOnly: true,
  run: ({ order_id }) => shop.helpdesk.thread(order_id),
});

await wardrik.work();
```

Start it with a token that serves acme's agents:

```sh
wardrik token create disputes --scope acme/ --can serve
WARDRIK_TOKEN=wardrik_... node disputes.ts
```

### The policy

```yaml title="~/.config/wardrik/policies/disputes.yaml"
allow:
  - stripe/stripe_api_read
  - stripe/stripe_api_search
  - stripe/stripe_api_details
  - workers/find_order
  - workers/shipment
  - workers/customer_messages
ask:
  stripe/stripe_api_write: This files dispute evidence with Stripe.
budget:
  usd: 1.00
  per: turn
  on_exhausted: ask
```

- Every Stripe write waits, so nothing reaches Stripe without a person. The webhook's body is
  [outside content](/concepts/outside-content/), so even an `allow` couldn't let a write through.
- `per: turn` gives each dispute its own dollar. See [Budgets](/concepts/budgets/).

### The agent

```markdown title="~/.config/wardrik/agents/disputes.md"
---
description: Builds the evidence for each new Stripe dispute and proposes the submission.
tools: [stripe/*, workers/*]
policy: disputes
notify: {to: [disputes], on: [parked, failed, finished]}
triggers:
  - name: stripe
    webhook:
      secret: ${STRIPE_HOOK_SECRET}
    prompt: A Stripe event is below. If it's a new dispute, build the case.
---
You win chargebacks for Acme. For a new dispute, find what it's about with Stripe, then gather the
order, the shipment and every message with the customer.

Write the evidence for the dispute's reason: what was bought, that it arrived (carrier, tracking
number, delivery date), and what the customer said. Then propose one Stripe write that updates the
dispute with that evidence and submits it.

If the evidence is weak, say why in a line, and propose nothing.
```

The webhook trigger asks the agent about each request Stripe sends, with the body under the prompt.
See [Receiving a webhook](/build/triggers/#receiving-a-webhook).

## Try it

Read the agent file, and print the trigger's address:

```sh
wardrik reload
wardrik triggers
```

The address is under `base_url`, as `https://agents.acme.example/v1/hooks/acme/disputes/stripe`.
In Stripe, under **Developers › Webhooks**, add an endpoint at that address with your secret on the
end, `…/stripe/<STRIPE_HOOK_SECRET>`, for the event `charge.dispute.created`. Then make a test
dispute with the [Stripe CLI](https://docs.stripe.com/stripe-cli):

```sh
stripe trigger charge.dispute.created
```

The case appears in `#disputes` as a call waiting for you: the Stripe write, with the evidence it
would file as its arguments, and **Approve** and **Deny**. Approve it, and the evidence is filed.
Deny it with a reason, and the agent reads why.

## What it shows

- **A webhook as the trigger.** Each dispute starts its own turn, with no polling.
- **Retries run once.** Stripe resends an event it isn't sure arrived; the agent is asked once.
- **Bursts queue.** Ten disputes at once are ten turns, one after another; none is dropped.
- **Outside content can't file anything.** The dispute's text can't talk the agent into a write.
- **Your data stays in your app.** The agent reads orders through your code, with your keys.
- **A record of every case:** what it read, what it proposed, and who approved.

## Details

### How retries are recognised

A request that presents the secret is known by its `Idempotency-Key` header, or by the SHA-256 of
its body when it sends none. Stripe sends none and resends the same event, so a retry matches the
first delivery and is asked about once. A request the daemon can't take now gets `503`, and Stripe
tries again later.

### Why the secret is in the URL

Stripe signs its webhooks its own way, with `Stripe-Signature`. Wardrik checks a secret the sender
presents, or a [Standard Webhooks](https://www.standardwebhooks.com/) signature. Stripe can't send
an `Authorization` header, so the secret goes at the end of the URL, over HTTPS. A sender that signs
with Standard Webhooks, such as Clerk or Resend, uses `verify: standard` with its signing secret
instead:

```yaml
webhook:
  secret: ${CLERK_SIGNING_SECRET}
  verify: standard
```

### What Stripe's write does

Stripe files evidence with `POST /v1/disputes/{id}`. Its `submit` is `true` unless set to `false`,
so one approved call files the case. To stage evidence for a person to finish in the Stripe
Dashboard, have the agent send `submit: false`.

Text evidence such as `shipping_carrier`, `shipping_tracking_number`, `product_description` and
`uncategorized_text` goes in directly. Files, such as a receipt, are uploaded first with Stripe's
Files API.

### Stripe keys

From 31 October 2026, Stripe's MCP server takes only Agent API keys or OAuth. Restrict the key to
disputes and the reads the agent needs.

### Taking it further

- Put your refund and cancellation policies in the agent's files, and read them in with `context`.
- Send disputes over an amount to a different room with a second `notify` target.
- Watch deadlines: a [clock trigger](/build/triggers/) can ask each morning which cases are due
  within two days.
