---
title: Connect accounts
description: "Let each user connect their own accounts with OAuth, so their agents call MCP servers as them."
sidebar:
  order: 2
---

Let each user's agents call an MCP server as that user. Name an OAuth provider, and give the server
a `credential` of the same name:

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

Notice `credential: github` matches the provider's name. The first time one of a user's agents calls
the server, the user connects their own account.

Restart the daemon after changing `config.yaml`. `wardrik doctor` checks the vault and each server.
Accounts are sealed in the vault; see [Keep secrets in the vault](/build/vault/).

## Whose credential

Each call uses the credential the agent's owner holds:

- A user's agent uses that user's.
- An org's agent uses the org's.

Nothing falls back from one owner to another. A user's agent never reads its org's, and an org's
agent never reads a user's. The deployment's own secrets reach no agent; see
[The deployment's secrets](/build/vault/#the-deployments-secrets).

Where the owner holds none, and `oauth.providers` names a provider of the same name, the owner is
asked to connect an account. The account is kept in the vault as theirs from then on, so only their
agents reach it.

So one `credential` lets each user connect GitHub as themselves, while an org's agents use one token
the org [sealed](/build/vault/).

## Connect when an agent asks

The first time an agent needs an account its owner hasn't connected, the call parks. The link to
sign in is never in the conversation, an event or a notice. A person finds it:

- in Slack, with the notice's **Show link** button, shown only to whoever pressed it;
- over the HTTP API, at `GET /v1/agents/{agent}/interrupts/{interrupt}/authorization`.

The answer is a `url` to open, and a `code` to enter there for the device flow. Once the account is
connected, the call carries on by itself. A link is good for 15 minutes.

## Connect ahead of time

A person can connect before any agent asks:

```sh
wardrik connection ls --user jon             # the accounts offered, and which jon holds
wardrik connection connect github --user jon # prints where to sign in
wardrik connection disconnect github --user jon
```

With no `--org` or `--user`, these act for the deployment's org.

Over the HTTP API, with a token that reaches the owner's agents, `owner` names whose accounts:
`acme/@jon` for a user, or `acme` for an org.

```sh
curl -s -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/connections?owner=acme/@jon"
curl -s -X POST -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/connections/github?owner=acme/@jon"
curl -s -X DELETE -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/connections/github?owner=acme/@jon"
```

1. `GET` lists each account offered, and whether the owner holds it. It never answers a value.
2. `POST` answers the link to authorize at, or that the account is held already.
3. `DELETE` forgets the account. The next call that needs it asks again.

See [the HTTP API](/build/http-api/#connect-accounts).

## Where the browser goes back to

The provider sends the browser back to `/oauth/callback` on the daemon's `base_url`. Register that
as the redirect URI with a provider you registered by hand.

Without `base_url`, it's the [HTTP API](/build/http-api/) on the daemon's own machine,
`http://127.0.0.1:4747/oauth/callback`. For a daemon on another machine, forward the port first:

```sh
ssh -L 4747:127.0.0.1:4747 box
```

For people connecting from their own browsers, such as from a link in Slack, give the daemon a
public HTTPS address; see [A public address](/run/public-address/):

```yaml
base_url: https://agents.example.com
```

A provider with `flow: device` has the person enter a code on any device instead. That needs no
browser or open port on the daemon's side.

## Details

### Credentials on the wire

- A server reached over HTTP gets the credential as `authorization: Bearer <token>`.
  `credential_header` and `credential_scheme` change that.
- A server run as a command gets it in the environment variable `credential_env` names.

### Connecting, in full

- A call after a link's 15 minutes parks on a new link.
- Connecting asks nobody to approve. The account is held once the person has authorized.
- The audit records each account stored or removed, and who asked.
- Until anyone has connected, a server that needs an account offers one tool, `github__connect`, so
  an agent can begin. Once someone has, its tools are kept in the store.
- A token is refreshed when it expires. A refresh the provider refuses asks the owner to connect
  again.

### The provider

| Key | |
| --- | --- |
| `resource` | the server the token is for. Used to find the issuer if there's none |
| `issuer` | the authorization server, whose metadata names its endpoints |
| `authorization_endpoint`, `token_endpoint` | the endpoints, for a server without metadata |
| `client_id`, `client_secret` | a client registered with the provider by hand |
| `client_auth` | `post` sends the secret in the form, `basic` as HTTP Basic. `post` unless set |
| `scopes` | what to ask for. None unless set |
| `flow` | `browser` or `device` (RFC 8628). `browser` unless set |

A provider needs an `issuer`, a `resource`, or both endpoints.

Without a `client_id`, the daemon gets one the first time someone signs in:

1. If the provider reads Client ID Metadata Documents and `base_url` is HTTPS, the `client_id` is
   the document the daemon serves at `/oauth/client`.
2. Otherwise, the daemon registers itself with the provider.
