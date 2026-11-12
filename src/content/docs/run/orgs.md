---
title: Organizations, roles, and tokens
description: "Declare orgs, grant access with roles and bindings, and create tokens for users and programs."
sidebar:
  order: 6
---

API tokens identify users or agents. Roles define allowed operations, and bindings grant those
roles within an organization (org). Configure both in `config.yaml`.

```yaml title="~/.config/wardrik/config.yaml"
org: acme

orgs:
  payments: {mcp: [stripe], policy: payments-limits}

roles:
  reader: {rules: [{verbs: [read, events], kinds: [agent]}]}
  operator: {rules: [{verbs: ["*"], kinds: ["*"]}]}

bindings:
  - {org: payments, role: operator, subjects: [user:payments/@ana, group:payments-eng]}
  - {org: acme, role: reader, subjects: [user:acme/@jon, agent:triage]}
```

```sh
systemctl --user restart wardrik
wardrik token create ana-laptop --subject user:payments/@ana --groups payments-eng --expires 30d
```

## Orgs

- `org` is the deployment's org, `default` unless set. `orgs` declares the others.
- Agents, secrets, and servers must belong to a declared organization.
- A user is `ORG/@NAME`, such as `acme/@jon`. A user owns their agents, secrets and accounts.
- `orgs.<org>` lists the `mcp` servers, `channels` and `notify` targets its agents can use. `"*"`
  applies to every org.
- `orgs.<org>.policy` applies to every agent in the org, including its users' agents. They share
  its budget. See [Budgets](/concepts/budgets/).

## Roles and bindings

A role contains permission rules. Each rule specifies operations (`verbs`), resource types
(`kinds`), and optionally specific resources (`names`):

```yaml
roles:
  asker: {rules: [{verbs: [ask, read, events], kinds: [agent], names: [triage]}]}
```

- A verb is the operation name after the dot: `ask` for `agent.ask`. `"*"` matches every verb.
- Kinds are `agent`, `secret`, `ceiling`, `mcp_server`, `notify_target`, `provider`,
  `connection`, `deployment` and `token`.
- `names` lists agents by name, and other resources by ID.
- Creating an agent is `create` on `agent`. A rule with `names` doesn't allow it.
- Removing a secret, server, webhook, OAuth app, connection or token is `delete`. `create`
  doesn't include it.

A binding grants a role to users, groups, or agents in one organization, in `deployment`, or in
`"*"` for every org and the deployment. The `subjects` field accepts:

- `user:ORG/@NAME`: a user, such as `user:acme/@jon`.
- `group:NAME`: every token that lists the group.
- `agent:NAME`: the agent with that name in the binding's org, when calling its tools. In
  `deployment`, the agent of that name in the deployment's own org. `"*"` can't name an agent.

A binding in `deployment` reaches the deployment's own resources: its nodes, runtime and audit,
and the servers, secrets, notify targets and OAuth apps it owns. Tokens stay reachable only from
`"*"`. `wardrik init` binds the assistant there to read the deployment and
list its secrets by name:

```yaml
roles:
  observer:
    rules:
      - {verbs: [nodes, runtime, audit], kinds: [deployment]}
      - {verbs: [read], kinds: [secret]}
bindings:
  - {org: deployment, role: observer, subjects: [agent:assistant]}
```

## Built-in rules

- **Owners.** A user has full access to resources they own: agents, secrets, MCP servers, webhooks and
  OAuth apps.
- **Agents.** An agent calling its tools has only its own bindings, not its owner's.
- **Connections.** Each user manages only their own connected accounts.
- **Channels.** A chat member acts as the user `channels.<name>.domains` or `members` maps them
  to. They can only send messages, read, and approve or deny, on the agents of the owner who
  added the workspace. The member who started a turn can always approve its calls.
- **Admin.** The built-in `admin` role permits all operations on all resources. It cannot be
  redefined. The CLI uses `user:admin`, which has this role across all organizations.
- **Access errors.** Resources outside your authorized organizations return `404`. Within an
  authorized organization, an operation without permission returns `403`.

## Tokens

```sh
wardrik token create ci --subject user:acme/@ci --expires 90d
wardrik token create triage-bot --subject agent:triage     # authenticates as the agent
wardrik token ls
wardrik token revoke mzxw6ytboi
```

- The secret is printed once, as `wdk_...`. Only its hash is stored.
- `--groups` takes a comma-separated list of groups for bindings to match.
- `--expires` takes `s`, `m`, `h` or `d`. Default `30d`, maximum one year.
- Revoked tokens are rejected immediately. Its event streams and worker connections close within
  15 seconds.
- Over HTTP, tokens are at `/v1/tokens`.

Token creation requires a binding in `"*"` for the `token` resource type. This permission allows
the caller to act as the token’s subject. Restrict it with `names` to specify which identities
the caller can create tokens for:

```yaml
roles:
  issuer: {rules: [{verbs: [create], kinds: [token], names: ["user:acme/@ci"]}]}
bindings:
  - {org: "*", role: issuer, subjects: [user:acme/@jon]}
```

- `names` lists the subjects it can create tokens for.
- Listing tokens is `read`, and revoking one is `delete` on its ID.
- Only the admin can create a token for `user:admin`.

## The `wardrik` command's token

On each start, the daemon writes a token for `user:admin` to `~/.local/share/wardrik/cli_token`,
mode `600`. Set `WARDRIK_URL` and `WARDRIK_TOKEN` to use another daemon.

To map chat members to users, see [Slack › Members](/build/slack/#members).
