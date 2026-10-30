---
title: Orgs
description: "How an org keeps its agents, and each of its users' agents, apart from everyone else's."
sidebar:
  order: 6
---

Every agent belongs to an [org](/concepts/agents/#keys-and-orgs), and an org is the boundary between
agents. Inside an org, an agent works for the org itself or for one of its users, and each is kept
apart.

## Declare an org

The deployment's own org is `config.yaml`'s `org`, `default` unless set. Declare each other org
under `orgs`, with the servers, channels and notify targets it uses:

```yaml title="~/.config/wardrik/config.yaml"
org: platform

mcp:
  stripe: {url: https://mcp.stripe.com, credential: STRIPE_AGENT_KEY}

channels:
  payments-slack: {type: slack, token: "${PAYMENTS_SLACK_BOT_TOKEN}", signing_secret: "${PAYMENTS_SLACK_SIGNING_SECRET}"}

orgs:
  payments:
    mcp: [stripe]
    channels: [payments-slack]
```

Restart the daemon after a change. Anything for an org `config.yaml` doesn't declare is refused,
with the orgs it does declare. That covers:

- an agent file, or an agent defined over the HTTP API
- `wardrik vault put --org`, and servers and connections for the org
- `wardrik token create --resource`

A typo is caught the same way. See [`orgs`](/reference/config/#orgs).

A server, channel or target no org lists is the deployment's own org's. A channel serves one org,
or every org when `"*"` lists it.

## Hold an org to a policy

An org's `policy` is one every agent of the org is held to, ahead of its own:

```yaml title="~/.config/wardrik/config.yaml"
orgs:
  payments:
    policy: payments-limits
```

```yaml title="~/.config/wardrik/policies/payments-limits.yaml"
ask:
  stripe/stripe_api_write: This changes money in Stripe.
deny: [shell/*]
budget:
  usd: 20.00
  per: day
```

- It holds every agent in the org, and each of its users' agents: those from files, from the HTTP
  API, and from channels.
- An agent's own policy can narrow it, never widen it.
- Its budget is the org's. Every agent of the org, its users' included, spends from it together.
- Once they've spent it, the next model call any of them makes waits for a person. Approving it
  grants more to all of them, for the rest of the period.
- Each agent's own budget still counts apart. So does a budget `per: turn`, since a turn is one
  agent's.
- `"*"`'s policy holds every org, beside each org's own. Each org spends `"*"`'s budget apart.
- An org whose policy isn't in `policies/` runs none of its agents.
- The daemon reads `policies/` as it starts, so restart it after changing one.

A [token](/run/tokens/#what-agents-it-defines-may-do) can add a policy of its own over the agents it
defines.

## What stays inside an org

What reaches the org's agents reaches none of its users'. What reaches one user's agents reaches
neither the org's nor another user's. The exception is a resource pattern naming the whole org,
`acme/*`.

These belong to an org, or to one of its users, and reach only their agents:

- **Tokens** whose resources name the org, one of its users, or `acme/*`.
- **Shared trees** named for the org or a user, and those `workspace.shared` in `config.yaml`
  shares with others.
- **Connected accounts** of the org or a user. An agent uses only its own owner's. A user's agent
  never uses its org's.
- **Channel access:** people in a channel may read and message the agents of the org it serves,
  and none of their users'.
- **MCP servers, channels and notify targets**, which serve the orgs `orgs` lists them for, and the
  deployment's own org where none does.

## What the whole deployment shares

- `policies/`, which any agent file can name.
- API keys in the vault, such as a model provider's. An agent's calls use the nearest one: its
  user's, then its org's, then the deployment's. The agent itself never reads them.
- Credentials in an MCP server's `headers` or `env`, used for every org the server serves.
- The `wardrik` command, whose token is an `owner` on every org.
