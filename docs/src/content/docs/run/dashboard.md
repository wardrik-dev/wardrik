---
title: Use the dashboard
description: "Watch agents, approve calls, and manage servers, secrets and tokens in a browser."
sidebar:
  order: 7
---

The daemon serves a web dashboard at `/web`, on the HTTP API's port. Use it to see what each agent
does, approve or deny its calls, check each node's resource use, and manage MCP servers, secrets
and tokens.

```sh
wardrik web
# Open this link within two minutes to sign in:
# http://127.0.0.1:4747/web/sign-in?code=...
```

Open the link in a browser on the same machine. To use the dashboard from another machine, see
[From another machine](#from-another-machine).

## Signing in

- The link works for two minutes. Run `wardrik web` again for a new one.
- Signing in creates a token for the same user as the command. The session lasts 12 hours.
  Signing out revokes the token.
- Each page checks permissions as the HTTP API does. A user sees and changes only what their
  [roles](/run/orgs/) allow.
- A program can get a link with [`POST /v1/tokens/web`](/reference/http-api/#create-a-sign-in-link).
  Only user tokens can sign in.

## Pages

| Page | Shows |
| --- | --- |
| Agents | every agent and its status, conversations and runs; send a message, move or delete an agent |
| Approvals | calls that wait on a person; approve or deny each |
| Audit | who changed what |
| Nodes | each node's memory, processes and load, what runs on it, and the agents that use the most memory |
| Operations | a form for every operation in the [HTTP API](/reference/http-api/) |
| MCP servers, Secrets, Notify targets, OAuth apps | add and remove each; entries from `config.yaml` show but can't be removed here |
| Connections | your accounts on other services; connect and disconnect them |
| Ceilings | spending ceilings, and what each has spent |
| Tokens | create and revoke API tokens |
| Configuration | `config.yaml` as the daemon read it, with secrets hidden; edit the file to change it |

Changes made on a settings page apply at once, as they do through the HTTP API.

## From another machine

With [`base_url`](/reference/config/#keys) set, `wardrik web` links to
`{base_url}/web/sign-in`. Forward `/web/*` in the proxy as well as the
[public paths](/run/public-address/#exposed-paths):

```text title="/etc/caddy/Caddyfile"
agents.example.com {
	@daemon path /oauth/* /v1/hooks/* /v1/channels/* /v1/openapi.json /web/*
	handle @daemon {
		reverse_proxy 127.0.0.1:4747
	}
	handle {
		respond 404
	}
}
```

- The pages update over a WebSocket at `/web/live`. Caddy forwards it without more config.
- Each page needs a signed-in session. A request without one goes to the sign-in page.

## Turn it off

```yaml title="~/.config/wardrik/config.yaml"
web:
  enabled: false
```

`/web` then returns `404`, and `wardrik web` says the dashboard is off.
