---
title: Connect accounts
description: "Each user connects their own accounts with OAuth, so their agents call MCP servers with their credentials."
sidebar:
  order: 2
---

Define an OAuth provider, and set an MCP server's `credential` to its name:

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
- A code is single-use, valid for 10 minutes, and only for the user who started the sign-in.

## Your accounts

```sh
wardrik connection ls                    # available providers, and your connections
wardrik connection disconnect github     # delete it; the next call prompts again
```

Each command runs as the token's user. Users manage only their own accounts.

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

For a provider name, the first match is used: the user's app, the org's, then `config.yaml`'s.

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
  See [A public address](/run/public-address/).
- A provider needs an `issuer`, a `resource`, or both `authorization_endpoint` and
  `token_endpoint`. Every key is in [`config.yaml` › oauth](/reference/config/#oauth).
- Without a `client_id`, the daemon registers a client with the provider on the first sign-in.
- An HTTP server receives the token as `authorization: Bearer <token>`. A command server receives
  it in the environment variable named by `credential_env`.
- Tokens are refreshed on expiry. If a refresh fails, the user is prompted to connect again.
- Connections are stored in the [vault](/build/vault/).
