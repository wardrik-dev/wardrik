---
title: Tokens
description: "Make HTTP API tokens scoped to some agents and some actions, and revoke them."
sidebar:
  order: 5
---

Every HTTP API request presents a token. `wardrik token create` makes one, scoped to some agents and
some actions.

```sh
wardrik token create ci --scope acme/ --policy careful
wardrik token create watcher --scope acme/@ops/ --can read
wardrik token create shop --scope acme/ --can serve
wardrik token list
wardrik token revoke 3f9a61c0d4e2
```

The token is printed once. The store keeps only its SHA-256.

## Which agents it reaches

`--scope` names the agents, by key prefix:

| Scope | Reaches |
| --- | --- |
| `acme/` | acme's own agents, none of its users' |
| `acme/@jon/` | jon's agents in acme |
| `acme/*` | acme and every one of its users' |
| `acme/@jon/triage` | one agent |
| `--all` | every agent |

An agent outside the scope is answered as one that doesn't exist.

## What it may do

`--can` lists the actions, all of them unless you name fewer. An action it may not take is refused
with `403`.

| Action | Reaches |
| --- | --- |
| `read` | listing agents, their snapshots and their events |
| `message` | sending messages, and stopping a turn |
| `decide` | approving and denying waiting calls, and their authorization links |
| `define` | putting and removing agents and triggers |
| `serve` | offering tools as a [worker](/build/tool-workers/) |

## What agents it defines may do

A token that can `define` needs `--policy` or `--unlimited`.

- `--policy NAME` holds every agent the token defines to a policy in `policies/`, ahead of the
  definition's own. A definition can narrow it, never widen it.
- `--unlimited` adds no ceiling. Their org's [ceiling](/run/orgs/#hold-an-org-to-a-ceiling) and
  their own policies still hold them.

## Revoke a token

Tokens don't expire, so revoke the ones you no longer need. A revoked token is refused at once, and
its event streams and worker connections close.

## Details

- The full syntax:

  ```sh
  wardrik token create NAME (--scope PREFIX | --all) [--can ACTIONS] [--policy NAME | --unlimited]
  ```

- Revocation reaches every node it can at once, and any other node within 15 seconds.
- An agent a revoked token defined keeps running, under the policy it was defined with.
- Every option is in the [CLI reference](/reference/cli/#wardrik-token-create).
