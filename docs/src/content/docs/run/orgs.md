---
title: Orgs
description: "How an org keeps its agents, and each of its users' agents, apart from everyone else's."
sidebar:
  order: 6
---

Every agent belongs to an [org](/concepts/agents/#keys-and-orgs), and an org is the boundary between
agents. Inside an org, an agent works for the org itself or for one of its users, and each is kept
apart.

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
- **MCP servers and notice targets**, which serve the deployment's org unless `config.yaml` names
  others.

## What the whole deployment shares

- `policies/`, which any agent file can name.
- Vault credentials put for the deployment, which an agent reads only where `vault.shared` names
  them.
- Credentials in an MCP server's `headers` or `env`, used for every org the server serves.
- The terminal client, whose keys reach every org's agents.
