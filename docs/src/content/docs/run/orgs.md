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

The deployment's own org is `config.yaml`'s `org`. Declare each other org under `orgs`, with the
servers, channels and notify targets it uses:

```yaml title="~/.config/wardrik/config.yaml"
org: platform

mcp:
  stripe: {url: https://mcp.stripe.com, credential: STRIPE_AGENT_KEY}

channels:
  payments-slack: {type: slack, token: "${PAYMENTS_SLACK_BOT_TOKEN}", app_token: "${PAYMENTS_SLACK_APP_TOKEN}"}

orgs:
  payments:
    mcp: [stripe]
    channels: [payments-slack]
```

Restart the daemon after a change. Anything in an org that isn't declared is refused, and says
which orgs are: an agent file, an agent defined over the API, `wardrik vault put --org`,
`wardrik agent spawn --org` and `wardrik token create --scope`. A typo is caught the same way. See
[`orgs`](/reference/config/#orgs).

## What stays inside an org

What reaches the org's agents reaches none of its users'. What reaches one user's agents reaches
neither the org's nor another user's. The exception is a scope naming the whole tenant, `acme/*`.

These belong to an org, or one of its users, and reach only their agents:

- **Tokens** scoped to the org, one of its users, or the tenant.
- **Shared trees** named for the org or a user, and those `workspace.shared` in `config.yaml` shares
  with others.
- **Vault credentials** put for the org or a user, and the accounts they connect. An agent reads
  only its own owner's; a user's agent never reads its org's.
- **Channel access:** people in a channel may read and message the agents of the orgs it offers, and
  none of their users'.
- **MCP servers, channels and notice targets**, which serve the orgs `orgs` lists them for, and the
  deployment's org where none does.

## What the whole deployment shares

- `policies/`, which any agent file can name.
- Vault credentials put for the deployment, which an agent reads only where `vault.shared` names
  them.
- Credentials in an MCP server's `headers` or `env`, used for every org the server serves.
- The terminal client, whose keys reach every org's agents.
