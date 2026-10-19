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
wardrik token list
wardrik token revoke 3f9a61c0d4e2
```

The token is printed once. The store keeps only its SHA-256. A token an earlier release made
doesn't read; make it again.

## What a token is

Wardrik uses IAM's words. A token is what someone acts with:

- Its **principal** is who it acts for. A token you make acts for you.
- Its **statements** each allow some **actions** on some **resources**. Anything no statement allows
  is denied.
- An action is what a request does, such as `agent.ask` or `agents.list`. `agent.*` is every action
  on one agent, and `*` every action.
- A resource is named as IAM names one: a namespace, an org, `acme`, a user in it, `acme/@jon`, or
  `deployment`, then a type and a name. The agent `acme/@jon/triage` is `acme/@jon/agent/triage`,
  and answering for a thread, `acme/@jon/agent/triage/thread/1696.1234`; its trigger `hook` is
  `acme/@jon/agent/triage/trigger/hook`. An MCP server is `acme/server/crm`, an account or a
  secret `acme/@jon/secret/github`, and a token `deployment/token/3f9a61c0d4e2`.

## What it reaches

`--resource` names what it reaches, once or more, each a pattern: `*` matches anything, `/` too,
and `?` one character.

| Resource | Reaches |
| --- | --- |
| `acme/agent/*` | acme's own agents, with their threads, none of its users' |
| `acme/@jon/*` | everything of jon's in acme: his agents, servers and accounts |
| `acme/*` | everything of acme's and every one of its users' |
| `acme/agent/triage` | one agent; `acme/agent/triage/*` its threads and triggers |
| `*` | everything, the deployment's own included |

Nothing is implied: an agent and its threads are `acme/agent/triage` and `acme/agent/triage/*`. An
agent outside what it reaches is answered as one that doesn't exist, `404`.

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

The nodes, the audit, reloading, moving an agent and tokens themselves are the deployment's,
`deployment/*`. Only `owner` on `*` or `deployment/*` reaches them. An owner's servers are checked
as `acme/server/*`, and their accounts as `acme/secret/*`.

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
  wardrik token create NAME --resource PATTERN... --role ROLES [--policy NAME] [--expires DURATION]
  ```

- Over the HTTP API, an `owner` token on `*` makes, lists and revokes tokens at `/v1/tokens`.
- Revocation reaches every node it can at once, and any other node within 15 seconds.
- An agent a revoked token defined keeps running, under the policy it was defined with.
- Every option is in the [CLI reference](/reference/cli/#wardrik-token-create).
