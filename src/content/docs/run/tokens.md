---
title: Tokens
description: "Make HTTP API tokens that allow some actions on some resources, and revoke them."
sidebar:
  order: 5
---

Every HTTP API request presents a token. `wardrik token create` makes one: roles on some resources.

```sh
wardrik token create ci --resource 'acme/agent/*' --role reader,messenger,definer --policy careful
wardrik token create watcher --resource 'acme/@ops/*' --role reader
wardrik token create shop --resource 'acme/agent/*' --role worker --expires 30d
wardrik token ls
wardrik token revoke 3f9a61c0d4e2
```

The secret is printed once, as `wrk_...`. The store keeps only its SHA-256. Send it as
`Authorization: Bearer wrk_...`.

## What a token is

Wardrik uses IAM's words:

- A token's **principal** is who it acts for: whoever made it.
- Its **statement** allows some **actions** on some **resources**. Anything it doesn't allow is
  denied.
- An **action** is what a request does, such as `agent.ask` or `agent.read`.
- A **resource** names what it acts on: an owner, then a type and a name.

| Resource | Names |
| --- | --- |
| `acme/agent/triage` | the agent `acme/triage` |
| `acme/@jon/agent/triage` | the agent `acme/@jon/triage` |
| `acme/agent/triage/conversation/C1-1696.1234` | one of its conversations, as a Slack thread's |
| `acme/mcp_server/crm` | the org's MCP server `crm` |
| `acme/@jon/connection/github` | Jon's GitHub account |
| `acme/@jon/secret/NAME` | a secret Jon holds |
| `acme/ceiling` | the org's budget |
| `deployment` | the deployment itself |

## What it reaches

`--resource` names what it reaches, once or more, each a pattern. `*` matches any run of
characters, `/` included, and `?` one character.

| Pattern | Reaches |
| --- | --- |
| `acme/agent/*` | acme's own agents and their conversations, none of its users' |
| `acme/@jon/*` | everything of Jon's in acme: his agents, servers, accounts and secrets |
| `acme/*` | everything of acme's and of every one of its users |
| `acme/agent/triage` | one agent; `acme/agent/triage/*` its conversations |
| `*` | everything, the deployment included |

Nothing is implied: an agent and its conversations are `acme/agent/triage` and
`acme/agent/triage/*`. An agent outside what a token reaches is answered as one that doesn't exist,
`404`. A pattern naming an org `config.yaml` doesn't declare is refused.

## What it may do

`--role` names its roles, with commas. A role is a named set of actions. An action the token may
not take is refused with `403`.

| Role | Actions | Allows |
| --- | --- | --- |
| `reader` | `agent.read`, `agent.events`, `connection.read`, `mcp_server.read`, `ceiling.read` | listing agents, their snapshots, definitions, events, running calls and waiting calls; the servers, connections and budgets they use |
| `messenger` | `agent.ask`, `agent.cancel`, `agent.clear` | sending messages, cancelling turns, killing a running call, clearing a conversation |
| `approver` | `agent.decide` | approving and denying waiting calls, and their sign-in links |
| `definer` | `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget`, `connection.connect`, `mcp_server.add` | defining, starting, stopping and removing agents and their triggers; adding servers and connecting accounts |
| `worker` | `agent.serve` | offering tools as a [worker](/build/tool-workers/) |
| `owner` | `*` | everything |

Reloading, the nodes, the audit, moving an agent and tokens themselves act on `deployment`. Only
`owner` on `*` or `deployment` reaches them. Secrets need `owner` too.

A token can't do more than the token that makes it, on more of it.

## What agents it defines may do

`--policy NAME` names a policy in `policies/` that holds every agent the token defines, ahead of
the definition's own. This is what IAM calls a permissions boundary. A definition can narrow it,
never widen it. A token made by one held to a policy is held to it too.

The policy must be in `policies/` when the token is made. The org's
[policy](/run/orgs/#hold-an-org-to-a-policy) and the agent's own hold it either way.

## When it expires

A token you make works for 90 days, or for `--expires`, such as `30d`, `12h` or `15m`. Then it's
refused with `401`. It isn't refreshed: make another. A token can't outlast the token that makes
it.

## Revoke a token

```sh
wardrik token revoke 3f9a61c0d4e2
```

A revoked token is refused at its next request. Its open event streams and worker connections
close within 15 seconds. An agent it defined keeps running.

## Details

### The `wardrik` command's token

Each time the daemon starts, it revokes the last `wardrik` command token and makes a new one: an
`owner` on `*`, good for a year. It's in `~/.local/share/wardrik/cli_token`, readable by the
daemon's user alone. To point the command at another daemon, set `WARDRIK_URL` and
`WARDRIK_TOKEN`.

### Over the HTTP API

An `owner` token on `*` makes, lists and revokes tokens at `/v1/tokens`. See the
[HTTP API reference](/reference/http-api/).

### The full syntax

```sh
wardrik token create NAME --resource PATTERN... --role ROLES [--policy NAME] [--expires DURATION]
```

See the [CLI reference](/reference/cli/#wardrik-token-create).
