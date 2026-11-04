---
title: Orgs, roles and tokens
description: "Declare orgs, grant access with roles and bindings, and create tokens for users and programs."
sidebar:
  order: 6
---

Every request to the daemon has a token. The token identifies a user. The roles and bindings in
`config.yaml` define what that user can do, in which org.

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
- An agent, secret or server for an undeclared org is refused.
- A user is `ORG/@NAME`, such as `acme/@jon`. A user owns their agents, secrets and accounts.
- `orgs.<org>` lists the `mcp` servers, `channels` and `notify` targets its agents can use. `"*"`
  applies to every org.
- `orgs.<org>.policy` applies to every agent in the org, including its users' agents. They share
  its budget. See [Budgets](/concepts/budgets/).

## Roles and bindings

A role is a list of rules. A rule allows `verbs` on `kinds` of resource, limited to `names` if set:

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

A binding grants a role to subjects in one org:

- `user:ORG/@NAME`: a user, such as `user:acme/@jon`.
- `group:NAME`: every token that lists the group.
- `agent:NAME`: the agent with that name in the binding's org, when calling its tools.

## Built-in rules

- **Owners.** A user has every verb on what they own: agents, secrets, MCP servers, webhooks and
  OAuth apps.
- **Agents.** An agent calling its tools has only its own bindings, not its owner's.
- **Connections.** Each user manages only their own connected accounts.
- **Channels.** A chat member acts as the user `channels.<name>.members` maps them to. They can
  only send messages, read, and approve or deny, on the agents of the owner who added the
  workspace. The member who started a turn can always approve its calls.
- **Admin.** `admin` is every verb on every kind. `roles` can't declare it. `user:admin`, which
  the `wardrik` command runs as, has it in `"*"`.
- **Outside your orgs**, every resource returns `404`, so its existence isn't revealed. Inside, an
  action no rule allows returns `403`.

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
- A revoked token is refused immediately. Its event streams and worker connections close within
  15 seconds.
- Over HTTP, tokens are at `/v1/tokens`.

Creating a token needs a binding in `"*"` on the `token` kind. A token authenticates as its
subject, so this permission can impersonate anyone. Grant it sparingly, with `names` listing the
subjects:

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
