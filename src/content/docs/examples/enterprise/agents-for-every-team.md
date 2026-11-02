---
title: Agents for every team
description: "One deployment for every team. Each team is an org with its own credentials, Slack, roles and limits, and one audit log covers all."
sidebar:
  order: 3
---

The platform team runs one daemon. Payments and Growth are separate orgs, each with its own agents,
credentials, Slack app, users and spend limit. Each team creates its own agents, under a policy the
platform team defines.

This example shows the configuration, not a single agent.

## The files

```yaml title="~/.config/wardrik/config.yaml"
org: platform

mcp:
  stripe: {url: https://mcp.stripe.com, credential: stripe}
  github: {url: https://api.githubcopilot.com/mcp/, credential: github}

channels:
  payments-slack:
    type: slack
    token: ${PAYMENTS_SLACK_BOT_TOKEN}
    signing_secret: ${PAYMENTS_SLACK_SIGNING_SECRET}
    members: {U024BE7LH: user:payments/@ana}
  growth-slack:
    type: slack
    token: ${GROWTH_SLACK_BOT_TOKEN}
    signing_secret: ${GROWTH_SLACK_SIGNING_SECRET}
    members: {U0G9QF9C6: user:growth/@li}

orgs:
  payments: {mcp: [stripe, github], channels: [payments-slack], policy: payments-limits}
  growth: {mcp: [github], channels: [growth-slack], policy: growth-limits}

roles:
  builder:
    rules: [{verbs: ["*"], kinds: [agent, secret, mcp_server, notify_target]}]
  auditor:
    rules: [{verbs: [read, events, audit], kinds: ["*"]}]
bindings:
  - {org: payments, role: builder, subjects: [group:payments-eng]}
  - {org: growth, role: builder, subjects: [group:growth-eng]}
  - {org: "*", role: auditor, subjects: [user:platform/@security]}
```

- `orgs` defines each team's servers, channels and the policy for all its agents.
- Each Slack app lists only its own org's agents. `members` maps chat members to users.
- `builder` allows a team to create and run agents in its own org. Other orgs' agents return `404`.
- `auditor` can read every org's agents and events.

```yaml title="~/.config/wardrik/policies/payments-limits.yaml"
ask:
  stripe/stripe_api_write: This changes money in Stripe.
budget: {usd: 20.00, per: day, on_exhausted: ask}
```

Stripe writes always need approval, and the org is capped at $20 a day. `growth-limits.yaml`
follows the same pattern.

## Try it

Store each team's credentials under its org, then restart:

```sh
echo "$PAYMENTS_STRIPE_KEY" | wardrik vault put stripe --org payments --for header
echo "$PAYMENTS_GITHUB_TOKEN" | wardrik vault put github --org payments --for header
echo "$GROWTH_GITHUB_TOKEN" | wardrik vault put github --org growth --for header
systemctl --user restart wardrik
wardrik doctor
```

Create a token per engineer:

```sh
wardrik token create ana-laptop --subject user:payments/@ana --groups payments-eng
```

Create an agent in the `payments` org with that token:

```sh
curl -X POST -H "authorization: Bearer $ANA_TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/owners/payments/agents \
  -d '{
    "name": "refunds",
    "description": "Answers refund questions for support.",
    "instructions": "You look up charges in Stripe, and propose refunds.",
    "tools": ["stripe/*"],
    "channels": ["payments-slack"]
  }'
```

The response contains the agent ID. The agent calls Stripe with the `payments` org's key. Its
refunds need approval, because the org policy has `ask` on every Stripe write. The token can't
access `growth` agents.

## What it shows

- Agents, credentials and channels are scoped to their org. See [Orgs](/run/orgs/).
- Access is roles and bindings, as in Kubernetes RBAC. See [Orgs, roles and tokens](/run/orgs/).
- Teams create their own agents. The org's policy and budget apply to all of them.
- `wardrik audit` lists every change, across all orgs.
