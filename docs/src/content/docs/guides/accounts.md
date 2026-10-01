---
title: Connect accounts
description: Give MCP servers credentials kept in the vault, for each user, each org or the deployment, and let users connect their own accounts with OAuth.
sidebar:
  order: 3
---

An MCP server names the credential it is reached with, and the vault holds it: for each user, for
each org, or for the whole deployment. Where none is held and an OAuth provider has the same name,
the user connects their own account, in a browser or with a code, the first time one of their agents
calls the server.

```yaml title="~/.config/wardrik/config.yaml"
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
    credential: github
```

`credential: github` names the credential each call to the server is made with. Restart the daemon
after changing `config.yaml`, and `wardrik doctor` checks the vault and each server.

## Whose credential

The vault looks a credential up for each call, the most specific first, and the first it holds is
the one used:

1. the agent's user's, where the agent works for one;
2. its org's;
3. the deployment's.

Where none of them holds it and `oauth.providers` names a provider of the same name, the agent's
user is asked to connect an account, or its org where the agent has no user. The account is kept in
the vault from then on, as theirs.

So a deployment can let each user connect GitHub as themselves, give one org a shared key
instead, and give every agent the same Linear key, all through `credential` alone.

A call runs over a connection to the server for whoever's credential it used: a user's own, an
org's, or the deployment's. A server reached over HTTP is sent it as
`authorization: Bearer <token>`; `credential_header` and `credential_scheme` send it another way. A
server run as a command is given it in the environment variable `credential_env` names.

## A key for the vault

Tokens are sealed with AES-256-GCM, by the vault, and kept in the store, so every node of a cluster
can use them. The vault needs a key before anyone connects. The first `wardrik vault put` asks to
make one, and keeps it in `~/.local/share/wardrik/vault_key`, beside the store. With nothing to put
yet, make the file yourself, and restart the daemon, which reads it as it starts:

```sh
openssl rand -base64 32 > ~/.local/share/wardrik/vault_key
systemctl --user restart wardrik
```

To keep the key apart from the store, set `WARDRIK_VAULT_KEY` where the daemon reads its
environment, such as `~/.config/wardrik/env` under the service, or `vault.keys` in `config.yaml`.
Either is used in place of the file. Without a key nothing is sealed or read, and every call needing
a connected account fails; nothing falls back to plain text.

Keep the key safe, and out of the store's backups: without it, what the vault sealed cannot be read,
and with it and the store, it can.

### Changing the key

`vault.keys` takes several. The first seals, and any of them opens:

```yaml
vault:
  keys: ["${WARDRIK_VAULT_KEY_NEW}", "${WARDRIK_VAULT_KEY}"]
```

`vault.keys` is used in place of `vault_key`, so to change the key the daemon made, set
`WARDRIK_VAULT_KEY` to what the file holds.

A token is sealed with the new key the next time it is refreshed, and a secret you put the next time
you put it. Once a key is removed, a token sealed with it is not read, and its user connects again.

## Connecting

The first time an agent calls a server for a user who has not connected, and nothing their org or
the deployment holds stands in, the call parks, and the agent waits:

> To connect github, open its authorization link. This carries on once the account is connected.

The link is never in the conversation, an event or a notice. A person finds it:

- with `wardrik parked`, which prints `open URL`, or `enter CODE at URL`;
- in Slack, with the notice's Show link button, which shows it to whoever pressed it;
- over the HTTP API, at `GET /v1/agents/{key}/interrupts/{id}/authorization`.

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

The vault also keeps a secret you put there yourself, for the deployment, an org or a user:

```sh
wardrik vault put linear                   # every agent's, where nothing nearer holds linear
wardrik vault put pagerduty --org acme     # acme's agents'
wardrik vault put sentry --user jon        # jon's agents', in the deployment's org
wardrik vault ls                           # what it holds, and whose, never the values
wardrik vault rm pagerduty --org acme
```

`vault put NAME` asks for the value and does not show it as you type, or reads it from a pipe.
`--user USER` puts one for a single user, with `--org ORG` for one outside the deployment's org.
A secret put for a user, or their org, is found before an OAuth provider of the same name is asked
for, so it stands in for an account they would otherwise connect. `vault ls` lists the accounts
users connected too.
