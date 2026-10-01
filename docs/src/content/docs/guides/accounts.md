---
title: Connect accounts
description: Let each user connect their own account to an MCP server with OAuth, and keep the tokens sealed in the store with the vault.
sidebar:
  order: 3
---

A key in `config.yaml` makes every agent reach a server as the deployment. To have each user reach
it as themselves, an MCP server names the credential it needs, and each user connects their own
account, in a browser or with a code, the first time one of their agents calls it.

```yaml title="~/.config/wardrik/config.yaml"
vault:
  keys: ["${WARDRIK_VAULT_KEY}"]

oauth:
  providers:
    github:
      resource: https://api.githubcopilot.com/mcp/
      issuer: https://github.com/login/oauth
      client_id: ${GITHUB_CLIENT_ID}
      client_secret: ${GITHUB_CLIENT_SECRET}
      scopes: [repo]

mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    credential: user:github
```

`credential: user:github` says the server is reached as the agent's user, with the account they
connected through the provider `oauth` calls `github`. Restart the daemon after changing
`config.yaml`, and `wardrik doctor` checks the vault and each server.

## A key for the vault

Tokens are sealed with AES-256-GCM, by the vault, and kept in the store, so every node of a cluster
can use them. The vault needs a key, and the daemon makes none:

```sh
openssl rand -base64 32
```

Put it where the daemon reads its environment, such as `~/.config/wardrik/env` under the service,
as `WARDRIK_VAULT_KEY`, and name it in `vault.keys`. Without a key nothing is sealed or read, and
every call needing a connected account fails; nothing falls back to plain text.

Keep the key safe and apart from the store: without it, what the vault sealed cannot be read, and
with it and the store, it can.

### Changing the key

`keys` takes several. The first seals, and any of them opens:

```yaml
vault:
  keys: ["${WARDRIK_VAULT_KEY_NEW}", "${WARDRIK_VAULT_KEY}"]
```

A token is sealed with the new key the next time it is refreshed. Once a key is removed, a token
sealed with it is not read, and its user connects again.

## Whose account

| `credential` | Reached as | The agent needs |
| --- | --- | --- |
| `user:NAME` | the agent's user, with a connection of their own | `user` in its file |
| `org:NAME` | the agent's org, connected once for all of its agents | `org` in its file |

A server reached over HTTP is sent the token as `authorization: Bearer <token>`.
`credential_header` and `credential_scheme` send it another way. A server run as a command is given
it in the environment variable `credential_env` names.

## Connecting

The first time an agent calls a server for a user who has not connected, the call parks, and the
agent waits:

> To connect github, open its authorization link. This carries on once the account is connected.

The link is never in the conversation, an event or a notice. A person finds it:

- with `wardrik parked`, which prints `open URL`, or `enter CODE at URL`;
- in Slack, with the notice's Show link button, which shows it to whoever pressed it;
- over the HTTP API, at `GET /v1/agents/{org}/{user}/{name}/interrupts/{id}/authorization`.

Once the account is connected, the call carries on by itself, with nobody approving it. A link is
good for 15 minutes; a call after that parks on a new one.

Until any user has connected, a server that needs an account to list its tools offers one tool,
`github__connect`, so an agent can begin connecting. Once one has, its tools are kept in the store
and offered on every node.

### In a browser

The link opens the provider's page, and the provider sends the browser back to the daemon on
loopback, at `http://127.0.0.1:4599/callback/github`. Register that as the redirect URI with the
provider. `oauth.redirect.port` sets another port.

Loopback is the daemon's own machine, so the browser has to be there too. For a daemon on another
machine, forward the port first:

```sh
ssh -L 4599:127.0.0.1:4599 box
```

### On another device

Where the provider offers the device flow (RFC 8628), the person is given a code to enter at the
provider's page, from a phone or any browser anywhere, while the daemon asks the provider whether
they have. Nothing comes back to the daemon, so one on a server with no browser and no open port can
be connected from Slack.

### Which way

`flow` on a provider is `browser`, `device`, or `auto`, the default. `auto` uses the device flow
where the provider offers it and the daemon has no browser of its own to open, and the browser
otherwise.

## The provider

| Key | |
| --- | --- |
| `resource` | the server the token is for |
| `issuer` | the authorization server. Without it, it is found from the resource |
| `client_id`, `client_secret` | a client registered with the provider by hand |
| `scopes` | what to ask for. Without them, what the resource says it supports |
| `flow` | `browser`, `device` or `auto` |

Without a `client_id`, the daemon presents whichever identity the provider accepts: a client
metadata document at `oauth.client.document_url`, which you host, or a client it registers with the
provider itself. `client` also takes `name`, shown on the provider's page, and `client_uri`,
`logo_uri`, `policy_uri` and `tos_uri`.

A token is refreshed before it runs out, without asking the user. A refresh the provider refuses
asks the user to connect again, the same way.

## A secret you already hold

The vault also keeps a secret you put there yourself, such as a key for an org, for an agent whose
credential is `org:NAME`, or `named:NAME` for the whole deployment. There is no command for it yet:
put it from an IEx shell on the daemon, with `wardrik remote`:

```elixir
WardrikVault.put({:org, "pagerduty"}, "acme", System.fetch_env!("PAGERDUTY_KEY"))
```

An agent's credentials come from OAuth where `config.yaml` has a provider, and from the vault where
it has a key and no provider.
