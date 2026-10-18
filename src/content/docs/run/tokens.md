---
title: Tokens
description: "Make HTTP API tokens that allow some actions on some agents, and revoke them."
sidebar:
  order: 5
---

Every HTTP API request presents a token. `wardrik token create` makes one: roles on some agents.

```sh
wardrik token create ci --scope acme/ --role reader,messenger,definer --policy careful
wardrik token create watcher --scope acme/@ops/ --role reader
wardrik token create shop --scope acme/ --role worker --expires 30d
wardrik token list
wardrik token revoke 3f9a61c0d4e2
```

The token is printed once. The store keeps only its SHA-256.

## What a token is

Wardrik uses IAM's words. A token is what someone acts with:

- Its **principal** is who it acts for. A token you make acts for you.
- Its **statements** each allow some **actions** on some **resources**. Anything no statement allows
  is denied.
- An action is what a request does, such as `agent.ask` or `agents.list`. `agent.*` is every action
  on one agent, and `*` every action.
- A resource is the agents under a key prefix.

## Which agents it reaches

`--scope` names the agents, by key prefix:

| Scope | Reaches |
| --- | --- |
| `acme/` | acme's own agents, none of its users' |
| `acme/@jon/` | jon's agents in acme |
| `acme/*` | acme and every one of its users' |
| `acme/@jon/triage` | one agent |
| `--all` | every agent |

An agent outside the scope is answered as one that doesn't exist, `404`.

## What it may do

`--role` names its roles. A role is a named set of actions. An action it may not take is refused
with `403`.

| Role | Allows |
| --- | --- |
| `reader` | listing agents, their snapshots, definitions, events and running calls, their waiting calls, and the servers and connections they use |
| `messenger` | sending messages, cancelling turns, and clearing a conversation |
| `approver` | approving and denying waiting calls, and their authorization links |
| `definer` | defining, starting, stopping and removing agents, their triggers, killing a running call, and adding servers and connections |
| `worker` | offering tools as a [worker](/build/tool-workers/) |
| `owner` | everything |

The nodes, the audit, reloading, moving an agent and tokens themselves are the deployment's. Only
`owner` with `--all` reaches them.

## What agents it defines may do

`--policy NAME` names a policy in `policies/` that holds every agent the token defines, ahead of the
definition's own. This is what IAM calls a permissions boundary. A definition can narrow it, never
widen it. Without `--policy`, the token names yours, if you have one.

The agent reads the policy by its name each time it starts, so a change to the policy reaches it on
`wardrik reload`. An agent whose token names a policy `policies/` no longer holds doesn't start.

Their org's [policy](/run/orgs/#hold-an-org-to-a-policy) and their own policies hold them either way.

## When it expires

A token works for 90 days, or for `--expires`, such as `30d` or `12h`. An expired token is refused
with `401`. `config.yaml` sets the default:

```yaml title="~/.config/wardrik/config.yaml"
tokens:
  expires:
    api: 30d
```

## Revoke a token

Revoke a token you no longer need. A revoked token is refused at once, and its event streams and
worker connections close.

## Details

- The full syntax:

  ```sh
  wardrik token create NAME (--scope PREFIX | --all) --role ROLES [--policy NAME] [--expires DURATION]
  ```

- Over the HTTP API, a token over every agent makes, lists and revokes tokens at `/v1/tokens`.
- Revocation reaches every node it can at once, and any other node within 15 seconds.
- An agent a revoked token defined keeps running, under the policy it was defined with.
- Every option is in the [CLI reference](/reference/cli/#wardrik-token-create).
