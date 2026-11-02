---
title: Orgs, roles and tokens
description: "Declare orgs, say who may do what with roles and bindings, and give people and programs tokens."
sidebar:
  order: 5
---

Everyone reaching the daemon presents a token. The token names a user. `config.yaml`'s roles and
bindings say what that user may do, in which org.

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

- `org` is the deployment's own org, `default` unless set. `orgs` declares the others.
- An agent, secret or server for an org `config.yaml` doesn't declare is refused.
- A person is `ORG/@NAME`, as `acme/@jon`. Their agents, secrets and accounts are their own.
- `orgs.<org>` lists the `mcp` servers, `channels` and `notify` targets its agents use. `"*"`
  gives them to every org.
- `orgs.<org>.policy` holds every agent of the org, its people's too. Its budget is shared by them
  all. See [Budgets](/concepts/budgets/).

## Roles and bindings

A role is a list of rules. A rule allows `verbs` on `kinds` of resource, and only `names` if set:

```yaml
roles:
  asker: {rules: [{verbs: [ask, read, events], kinds: [agent], names: [triage]}]}
```

- A verb is the action after the dot: `ask` for `agent.ask`. `"*"` is every verb.
- Kinds are `agent`, `secret`, `ceiling`, `mcp_server`, `notify_target`, `provider`,
  `connection`, `deployment` and `token`.
- `names` lists agents by name, and anything else by ID.
- Making an agent is `create` on `agent`. A rule with `names` doesn't allow it.
- Removing a secret, server, webhook, OAuth app, connection or token is `delete`. Adding one
  doesn't allow it.

A binding gives a role to subjects in one org:

- `user:ORG/@NAME`: a person, as `user:acme/@jon`.
- `group:NAME`: everyone whose token lists the group.
- `agent:NAME`: the agent of that name in the binding's org, acting through its tools.

## Rules that always hold

- **Owners.** A person may do anything to what they own: their agents, secrets, MCP servers,
  webhooks and OAuth apps. `user:acme/@jon` owns what `acme/@jon` owns.
- **Agents.** An agent acting through its tools gets its own bindings, never its owner's.
- **Connections.** Everyone manages their own connected accounts, and no one else's.
- **Channels.** A chat member acts as the user `channels.<name>.members` maps them to. They may only
  ask, read and decide, on the agents of whoever added the workspace. Whoever asked for a turn may
  always decide its calls.
- **Admin.** `admin` is every verb on every kind. `roles` can't declare it. `user:admin`, which
  the `wardrik` command acts as, holds it in `"*"`.
- **Outside your orgs**, you find nothing, not even that something's there: `404`. Inside, an action
  no rule allows is `403`.

## Tokens

```sh
wardrik token create ci --subject user:acme/@ci --expires 90d
wardrik token create triage-bot --subject agent:triage     # acts as the agent, for its owner
wardrik token ls
wardrik token revoke mzxw6ytboi
```

- The secret is printed once, as `wdk_...`. Only its hash is kept.
- `--groups` takes groups, with commas, that bindings may name.
- `--expires` takes `s`, `m`, `h` or `d`. `30d` unless set, a year at most.
- A revoked token is refused at once. Its event streams and worker connections close within 15
  seconds.
- Over HTTP, tokens are at `/v1/tokens`.

Making a token needs a binding in `"*"` on the `token` kind. A token acts as its subject, so whoever
makes tokens may act as anyone. Give it sparingly, with `names` listing the subjects:

```yaml
roles:
  issuer: {rules: [{verbs: [create], kinds: [token], names: ["user:acme/@ci"]}]}
bindings:
  - {org: "*", role: issuer, subjects: [user:acme/@jon]}
```

- `names` lists the subjects it may make tokens for.
- Listing tokens is `read`, and revoking one is `delete` on its ID.
- Only the admin makes a token for `user:admin`.

## The `wardrik` command's token

Each time the daemon starts, it writes a token for `user:admin` to
`~/.local/share/wardrik/cli_token`, readable by its user alone. `WARDRIK_URL` and `WARDRIK_TOKEN`
point the command at another daemon.

## Channel members

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
    members: {U024BE7LH: user:acme/@ana, U0G9QF9C6: user:acme/@jon}
```

An unmapped member is refused, and told to ask an admin. `unmapped_members: allow` lets them act as
`user:slack:<workspace>/<member>` instead, for a small deployment.
