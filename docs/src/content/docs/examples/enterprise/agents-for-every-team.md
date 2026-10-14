---
title: Agents for every team
description: "One deployment serves every team: each its own org, credentials, Slack, budget and limits, with one audit trail."
sidebar:
  order: 3
---

The platform team runs one Wardrik deployment. Payments and Growth each get an org of their own:
their own agents, credentials, Slack app and spend limits. Each team builds its agents over the API,
but only inside a policy the platform team sets. Security reads one audit trail for all of it.

This example is the setup, not one agent: `config.yaml`, a ceiling policy per team, and the tokens
that tie them together.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key;
- a [Slack app](/channels/slack/#a-slack-app) per team;
- each team's credentials for the services it uses, here Stripe for Payments and GitHub for both.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
org: platform

mcp:
  stripe:
    url: https://mcp.stripe.com
    credential: STRIPE_AGENT_KEY
    org: payments
  github:
    url: https://api.githubcopilot.com/mcp/
    credential: GITHUB_TOKEN
    org: [payments, growth]

channels:
  payments-slack:
    type: slack
    org: payments
    token: ${PAYMENTS_SLACK_BOT_TOKEN}
    app_token: ${PAYMENTS_SLACK_APP_TOKEN}
    approvers: ["@payments-lead"]
  growth-slack:
    type: slack
    org: growth
    token: ${GROWTH_SLACK_BOT_TOKEN}
    app_token: ${GROWTH_SLACK_APP_TOKEN}
    approvers: ["@growth-lead"]

vault:
  shared: [SEARCH_API_KEY]
```

- **Servers belong to orgs.** Stripe serves Payments alone; GitHub serves both, each with its own
  token.
- **Each team has its own Slack app,** offering only its own org's agents.
- **Shared secrets are named.** Every agent may read `SEARCH_API_KEY`; no other deployment secret
  reaches an agent.

Each team's credentials are sealed for its org, where no other team's agents can read them:

```sh
wardrik vault put STRIPE_AGENT_KEY --org payments
wardrik vault put GITHUB_TOKEN --org payments
wardrik vault put GITHUB_TOKEN --org growth
wardrik vault put SEARCH_API_KEY
```

See [Orgs](/run/orgs/) for everything an org keeps apart.

### A ceiling per team

A ceiling is a policy every agent a token defines is held to, ahead of its own:

```yaml title="~/.config/wardrik/policies/payments-ceiling.yaml"
ask:
  stripe/stripe_api_write: This changes money in Stripe.
deny: [run_lua]
budget:
  usd: 20.00
  per: day
  on_exhausted: ask
```

- **Stripe writes always wait,** whatever a team's own definition says.
- **Each agent is capped** at $20 a day. A team's definition can set a lower limit, never a higher
  one.

### A token per team

```sh
wardrik token create payments-platform --scope payments/ --can read,define,message --policy payments-ceiling
wardrik token create growth-platform --scope growth/ --can read,define,message --policy growth-ceiling
```

- `--scope` keeps each token to its team's own agents; another team's are answered as if they
  didn't exist.
- `--policy` is the ceiling. See [Tokens](/run/tokens/).

## Try it

The Payments team defines an agent with its token, over the [HTTP API](/build/http-api/):

```sh
curl -s -X PUT -H "authorization: Bearer $PAYMENTS_TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/payments/refunds \
  -d '{
    "description": "Answers refund questions for support.",
    "instructions": "You look up charges and refunds in Stripe, and propose refunds.",
    "tools": ["stripe/*"],
    "channels": ["payments-slack"]
  }'
```

The agent reads Stripe with Payments' key. A refund it proposes waits for an approver, because the
ceiling asks about every Stripe write. The same token can't reach Growth's agents, and Growth's
agents can't reach Stripe at all.

## What it shows

- **Isolation by org.** Agents, credentials, tokens and channels stay inside their team.
- **Self-service within limits.** Teams build their own agents; the platform team's ceiling holds
  every one.
- **Spend limits per agent,** set once for a whole team.
- **One audit trail.** Every change people make, and every call and decision agents make, is on
  record.

## Details

### Feeding a SIEM

A token over every agent can read one export across every team's logs, and the audit of what
people changed:

```sh
wardrik token create siem --all --can read
```

```http
GET /v1/exports/siem?limit=500

POST /v1/exports/siem
{"next": "eyJwYXltZW50cy9yZWZ1bmRzIjo0MX0"}
```

Each page answers the events after the export's cursor; posting the page's `next` moves it on once
they're stored. See [Exports](/reference/http-api/#exports). From a shell, `wardrik audit` lists
what people changed.

### People's own agents

An agent that works for one person is keyed under them, `payments/@jon/assistant`, and reads only
that person's credentials. A token for them is scoped the same way:
`wardrik token create jon-laptop --scope payments/@jon/ --can read,message,decide --for jon`.

### Taking it further

- Give a third team an org, a Slack app and a ceiling: no other change is needed.
- Let a team's agents read a shared runbook tree with `workspace.shared`. See
  [Sharing trees](/concepts/files-and-memory/#sharing-trees).
