---
title: Agents for every team
description: "One deployment serves every team: each its own org, credentials, Slack, roles and limits, with one audit trail."
sidebar:
  order: 3
---

The platform team runs one daemon. Payments and Growth each get an org: their own agents,
credentials, Slack app, people and spend limit. Each team makes its own agents, inside a policy the
platform team sets.

This example is the setup, not one agent.

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

- `orgs` says what each team's agents use, and the policy that holds all of them.
- Each Slack app offers only its own org's agents. `members` maps chat members to users.
- `builder` lets a team make and run agents in its own org. Another team's are answered as missing.
- `auditor` reads every org's agents and events.

```yaml title="~/.config/wardrik/policies/payments-limits.yaml"
ask:
  stripe/stripe_api_write: This changes money in Stripe.
budget: {usd: 20.00, per: day, on_exhausted: ask}
```

Stripe writes always wait, and the whole team is capped at $20 a day. `growth-limits.yaml` is
written the same way.

## Try it

Seal each team's credentials for its org, then restart:

```sh
echo "$PAYMENTS_STRIPE_KEY" | wardrik vault put stripe --org payments --for header
echo "$PAYMENTS_GITHUB_TOKEN" | wardrik vault put github --org payments --for header
echo "$GROWTH_GITHUB_TOKEN" | wardrik vault put github --org growth --for header
systemctl --user restart wardrik
wardrik doctor
```

Give each engineer a token:

```sh
wardrik token create ana-laptop --subject user:payments/@ana --groups payments-eng
```

Ana makes an agent in her team's org:

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

The answer holds the agent's ID. It reads Stripe with Payments' key. A refund it proposes waits,
because the org's policy asks about every Stripe write. Ana's token can't reach Growth's agents.

## What it shows

- Agents, credentials and channels stay inside their org. See [Orgs](/run/orgs/).
- Who may do what is roles and bindings, as in Kubernetes. See [Orgs, roles and tokens](/run/orgs/).
- Teams build their own agents. The org's policy and budget hold every one.
- `wardrik audit` lists what people changed, for every team.
