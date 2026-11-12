---
title: Connect accounts
description: "Each user connects their own accounts with OAuth, so their agents call MCP servers with their credentials."
sidebar:
  order: 2
---

Connect each user’s account so agents can call MCP tools with that user’s credentials.
Define an OAuth provider, then reference it in the MCP server’s `credential` setting:

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

- An agent calls the server with its owner's account.
- `flow: device` prints a code to enter at the provider. The command exits when the sign-in is
  granted, declined or expired.
- Without `flow: device`, it prints a link. Sign in, then enter the code the page shows, or run
  `wardrik connection pair github CODE`.
- Pairing codes are single-use, expire after 10 minutes, and belong to the user who started the sign-in.

## Your accounts

```sh
wardrik connection ls                    # available providers, and your connections
wardrik connection disconnect github     # delete it; the next call prompts again
```

Commands use the identity associated with your token. Users can manage only their own account connections.

## Calls before connecting

If an agent calls the server before its owner connects, the call pauses. The sign-in link is never
added to the conversation or a notice. Get it from:

- the notice's **Show link** button in Slack, visible only to the user who clicks it;
- `GET /v1/agents/{agent}/interrupts/{interrupt}/authorization`, as `{"url": ..., "code": ...}`.

Once the account is connected, the call resumes.

## OAuth apps added at runtime

An org or user can add their own OAuth app while the daemon runs:

```sh
echo "$LINEAR_SECRET" | wardrik vault put LINEAR_SECRET --org acme --for client_secret
wardrik provider add linear --org acme \
  --issuer https://linear.app --client-id abc123 --secret LINEAR_SECRET --scope read
wardrik provider ls --org acme
```

When multiple OAuth apps have the same provider name, Wardrik uses the user’s app first, then
the organization’s, then the app in `config.yaml`.

## Over HTTP

```sh
curl -s -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/connections
# {"connections": [{"provider": "github", "connected": false, "signing_in": false}]}

curl -s -X POST -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/connections/github
# {"provider": "github", "connected": false, "authorization": {"url": "https://…", "code": "BCDF-GHJK"}}
```

- `signing_in` is `true` while a sign-in you started is in progress.
- `POST /v1/connections/{provider}/pair` completes a browser sign-in with its code.
- `DELETE /v1/connections/{provider}` deletes the connection.
- Apps added at runtime are at `/v1/owners/{owner}/providers`. See the
  [HTTP API reference](/reference/http-api/).

## Details

- Browser sign-ins redirect to `{base_url}/oauth/callback`. Register that URL with the provider.
  See [Public HTTPS access](/run/public-address/).
- A provider needs an `issuer`, a `resource`, or both `authorization_endpoint` and
  `token_endpoint`. See all settings in [`config.yaml` › oauth](/reference/config/#oauth).
- Without a `client_id`, the daemon registers a client with the provider on the first sign-in.
- An HTTP server receives the token as `authorization: Bearer <token>`. A command server receives
  it in the environment variable named by `credential_env`.
- Tokens are refreshed on expiry. If a refresh fails, the user is prompted to connect again.
- Connections are stored in the [vault](/build/vault/).
