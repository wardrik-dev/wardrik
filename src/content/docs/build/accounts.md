---
title: Connect accounts
description: "Let each person connect their own accounts with OAuth, so their agents call MCP servers as them."
sidebar:
  order: 2
---

Name an OAuth provider, and give an MCP server a `credential` of the same name:

```yaml title="~/.config/wardrik/config.yaml"
base_url: https://agents.example.com

oauth:
  providers:
    github:
      issuer: https://github.com/login/oauth
      resource: https://api.githubcopilot.com/mcp/
      client_id: ${GITHUB_CLIENT_ID}
      client_secret: ${GITHUB_CLIENT_SECRET}
      scopes: [repo]
      flow: device

mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    credential: github
```

Restart the daemon, then connect your account:

```sh
wardrik connection connect github
```

```text
Sign in to github at https://github.com/login/device with the code BCDF-GHJK
Connected github.
```

- An agent calls the server with its owner's account. Jon's agents use Jon's.
- `flow: device` shows a code to enter at the provider. The command stops as soon as the sign-in
  is granted, declined or expires.
- Without `flow: device`, it prints a link. Sign in, then type the code the page shows, or run
  `wardrik connection pair github CODE`.
- A code works once, for 10 minutes, for the person who started the sign-in.

## Your accounts

```sh
wardrik connection ls                    # what you can connect, and what you hold
wardrik connection disconnect github     # forget it; the next call asks again
```

Each command acts as the person the token names. Every person manages only their own accounts.

## When an agent asks first

If an agent calls the server before its owner connects, the call waits. The link is never put in
the conversation or a notice. Find it:

- in Slack, with the notice's **Show link** button, shown only to whoever pressed it;
- at `GET /v1/agents/{agent}/interrupts/{interrupt}/authorization`, as `{"url": ..., "code": ...}`.

Once the account is connected, the call carries on.

## OAuth apps people add

An org or a person can add their own OAuth app while the daemon runs:

```sh
echo "$LINEAR_SECRET" | wardrik vault put LINEAR_SECRET --org acme --for client_secret
wardrik provider add linear --org acme \
  --issuer https://linear.app --client-id abc123 --secret LINEAR_SECRET --scope read
wardrik provider ls --org acme
```

A person signs in with the nearest app of a name: their own, their org's, then `config.yaml`'s.

## Over HTTP

```sh
curl -s -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/connections
# {"connections": [{"provider": "github", "connected": false, "signing_in": false}]}

curl -s -X POST -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/connections/github
# {"provider": "github", "connected": false, "authorization": {"url": "https://…", "code": "BCDF-GHJK"}}
```

- `signing_in` says a sign-in you started is still under way.
- `POST /v1/connections/{provider}/pair` finishes a browser sign-in with its code.
- `DELETE /v1/connections/{provider}` forgets the account.
- Apps people add are at `/v1/owners/{owner}/providers`. See the
  [HTTP API reference](/reference/http-api/).

## Details

- Browser sign-ins come back to `{base_url}/oauth/callback`. Register that with the provider. See
  [A public address](/run/public-address/).
- A provider needs an `issuer`, a `resource`, or both `authorization_endpoint` and
  `token_endpoint`. Every key is in [`config.yaml` › oauth](/reference/config/#oauth).
- Without a `client_id`, the daemon registers itself with the provider the first time someone signs
  in.
- A server over HTTP gets the account as `authorization: Bearer <token>`. A server run as a command
  gets it in the variable `credential_env` names.
- A token is refreshed when it expires. A refused refresh asks the person to connect again.
- Accounts are sealed in the [vault](/build/vault/).
