---
title: Manage from an MCP client
description: "Connect Claude Code or another MCP client to the daemon, and manage agents, approvals, servers, secrets and tokens from it."
sidebar:
  order: 7.5
---

The daemon serves its whole HTTP API as MCP tools at `/mcp`, on the HTTP API's port. Connect an
MCP client, such as Claude Code, to create and run agents, approve calls, and manage servers,
secrets and tokens.

## Connect Claude Code

```sh
wardrik token create claude-code --subject user:admin
export TOKEN=wdk_...
claude mcp add --transport http wardrik http://127.0.0.1:4747/mcp \
  --header "Authorization: Bearer $TOKEN"
```

- The token is printed once. A `user:admin` token can do everything the admin can.
- To limit what the client can do, use another subject, such as `user:acme/@jon`. See
  [Organizations, roles, and tokens](/run/orgs/).
- For a daemon on another host, use its [public address](/run/public-address/).

In Claude Code, run `/mcp` to check that `wardrik` is connected.

## What the tools do

- Each route of the [HTTP API](/reference/http-api/) is one tool, named after its operation with
  `_` for `.`. For example, `agent.ask` is `agent_ask` and `tokens.create` is `tokens_create`.
- A tool's arguments are the route's path parameters, query parameters and body, together.
- Each call is checked against the token's access, as the HTTP route is. A refused call returns
  the error to the client.
- Webhook and chat app deliveries are not tools.
- Tools that only read are marked read-only. Tools that delete are marked destructive.

Create agents with `agents_create`, which takes the owner, a name and the definition.
`agent_define` updates an agent that exists.

## Limits

- The endpoint takes a bearer token. It does not offer an OAuth sign-in, so clients that need
  one, such as connectors added in a browser, cannot connect.
- Each request gets one JSON answer. Calls do not stream: `agent_events` returns one page of
  events.
