---
title: Connect accounts
description: "Let each user connect their own accounts with OAuth, so their agents call MCP servers as them."
sidebar:
  order: 2
---

An MCP server names the credential it is reached with. Where the agent's owner doesn't hold it, and
an OAuth provider has the same name, the owner connects their own account the first time one of
their agents calls the server.

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

Restart the daemon after changing `config.yaml`. `wardrik doctor` checks the vault and each server.
The vault needs a key before anyone connects; see [Keep secrets in the vault](/build/vault/).

## Whose credential

The vault finds a credential for each call as the agent's owner holds it:

- an agent that works for a user reads that user's;
- an agent that works for nobody reads its org's.

Nothing falls back from one owner to another. A user's agent never reads its org's, and an org's
agent never reads a user's, so whoever may ask an agent may use what its owner holds and nothing
else. The deployment's own secrets reach an agent only where `vault.shared` names them; see
[Shared secrets](/build/vault/#shared-secrets).

Where the owner holds none and `oauth.providers` names a provider of the same name, the owner is
asked to connect an account: the user, or the org for an agent that works for nobody. The account
is kept in the vault from then on, as theirs, and acts as them, so only their agents reach it.

So a deployment can let each user connect GitHub as themselves, give an org's own agents one key,
and share a single search key with every agent, all through `credential` and `vault.shared`.

## Connecting

The first time an agent needs an account its owner hasn't connected, the call parks:

> To use github__create_issue, connect github at its link. This carries on once it is connected.

The link is never in the conversation, an event or a notice. A person finds it:

- with `wardrik parked`, which prints `open URL`, or `enter CODE at URL`;
- in Slack, with the notice's **Show link** button, shown only to whoever pressed it;
- over the HTTP API, at `GET /v1/agents/{key}/interrupts/{id}/authorization`.

Once the account is connected, the call carries on by itself. A link is good for 15 minutes.

### Before any agent asks

A person can connect ahead of time over the HTTP API, with a token that reaches their agents.
`owner` names whose accounts: theirs, `acme/@jon`, or their org's, `acme`:

```sh
curl -s -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/connections?owner=acme/@jon"
curl -s -X POST -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/connections/linear?owner=acme/@jon"
curl -s -X DELETE -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/connections/linear?owner=acme/@jon"
```

The list says who holds each account, never a value. `POST` answers the link to authorize at.
`DELETE` forgets the account. See [the HTTP API](/build/http-api/#connect-accounts).

## Where the browser goes back to

The provider sends the browser back to the daemon at its redirect URL, with `/callback/` and the
provider's name after it. Register that as the redirect URI with a provider you registered by hand.

Without `oauth.redirect.url`, it is `/oauth` on the daemon's [HTTP API](/build/http-api/), on its
own machine: `http://127.0.0.1:4747/oauth/callback/github`. For a daemon on another machine, forward
the port first:

```sh
ssh -L 4747:127.0.0.1:4747 box
```

For people connecting from their own browsers, such as from a link in Slack, give the daemon a
public HTTPS address; see [A public address](/run/public-address/):

```yaml
oauth:
  redirect:
    url: https://agents.example.com/oauth
```

Where a provider offers the device flow, the person can instead enter a code on any device. That
needs no browser or open port on the daemon's side.

## Details

### Credentials on the wire

A call runs over a connection made with whoever's credential it used: a user's own, an org's, or
the deployment's shared one. A server reached over HTTP gets it as `authorization: Bearer <token>`;
`credential_header` and `credential_scheme` change that. A server run as a command gets it in the
variable `credential_env` names.

### Connecting, in full

- A call after a link's 15 minutes parks on a new link.
- Connecting asks nobody to approve; the account is held once the person has authorized.
- The connections list says whether the person, their org or the deployment holds each account.
  `?owner=acme` acts on the org's, for a token that reaches the org's agents.
- The audit records each account stored or removed, and who asked.
- Until any user has connected, a server that needs an account to list its tools offers one tool,
  `github__connect`, so an agent can begin. Once one has, its tools are kept in the store and
  offered on every node.
- Without `oauth.redirect.url`, the daemon opens the link in a browser on its own machine.

### Which flow

`flow` on a provider is `browser`, `device` (RFC 8628), or `auto`, the default. `auto` uses the
device flow where the provider offers it and the daemon has no browser of its own; otherwise the
browser.

### The provider

| Key | |
| --- | --- |
| `resource` | the server the token is for |
| `issuer` | the authorization server. Without it, it is found from the resource |
| `client_id`, `client_secret` | a client registered with the provider by hand |
| `scopes` | what to ask for. Without them, what the resource says it supports |
| `authorization_params` | more to send with the authorization request in a browser |
| `flow` | `browser`, `device` or `auto` |

Google gives a refreshable token only with `access_type: offline`, and again after the first time
only with `prompt: consent`:

```yaml
authorization_params:
  access_type: offline
  prompt: consent
```

`authorization_params` can't set what the daemon sends itself, such as `redirect_uri`, `state` or
`scope`; a provider whose params name one doesn't read.

Without a `client_id`, the daemon presents whichever identity the provider accepts: a client
metadata document at `oauth.client.document_url`, which you host, or a client it registers itself.
`client` also takes `name`, shown on the provider's page, and `client_uri`, `logo_uri`,
`policy_uri` and `tos_uri`.

A token is refreshed before it runs out. A refresh the provider refuses asks the user to connect
again.
