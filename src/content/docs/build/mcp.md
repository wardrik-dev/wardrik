---
title: Connect MCP servers
description: "Add MCP servers in config.yaml or at runtime, list their tools in an agent, and set which calls need approval."
sidebar:
  order: 1
---

Define MCP servers in `config.yaml`, as a `command` or a `url`:

```yaml title="~/.config/wardrik/config.yaml"
mcp:
  linear:
    url: https://mcp.linear.app/mcp
    headers:
      authorization: Bearer ${LINEAR_TOKEN}
  notes:
    command: /usr/bin/npx
    args: [-y, "@modelcontextprotocol/server-filesystem", /srv/notes]
    only: [read_file, list_directory]
```

```sh
echo "$LINEAR_TOKEN" | wardrik vault put LINEAR_TOKEN --for header   # keeps the secret out of the file
systemctl --user restart wardrik
wardrik doctor                                                       # checks each server
```

List the tools in an agent file:

```yaml
tools: [linear/*, notes/*]
```

- In a policy, one tool is `linear/search_issues`.
- `only` and `except` filter a server's tools.
- `headers` and `env` are deployment credentials, shared by every org that uses the server. To
  call a server as each user, set `credential`. See [Connect accounts](/build/accounts/).
- Every key is in [`config.yaml` › mcp](/reference/config/#mcp).

## Which calls need approval

A tool the server doesn't mark read-only needs approval, unless a policy allows it:

```yaml
mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    credential: github
    gated: [create_*, merge_*, delete_*]
  runbooks:
    url: http://runbooks.internal:8080/mcp
    trusted: true
```

- `gated` lists the gated tools, `true` for all, or `false` for none.
- Without `trusted: true`, a server's results are [content from outside](/concepts/outside-content/).

See [Gated tools](/concepts/policy/#gated-tools).

## Which orgs can use a server

A server is available to the deployment's org. List it under `orgs` for other orgs:

```yaml
orgs:
  "*":
    mcp: [docs]          # every org
  globex:
    mcp: [globex-crm]    # globex only
```

## Servers added at runtime

An org or user can add a server for their own agents without editing `config.yaml`:

```sh
wardrik server add linear --url https://mcp.linear.app/mcp --oauth --user maria
wardrik server ls --user maria
wardrik server rm linear --user maria
```

Authentication:

- `--oauth`, with one `--scope` per scope: the owner signs in in a browser at the URL `server add`
  prints.
- `--secret NAME`: a vault secret the owner stored `--for header`.
- neither: no authentication.

Over HTTP:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/owners/acme%2F%40maria/servers \
  -d '{"name": "linear", "url": "https://mcp.linear.app/mcp", "auth": {"oauth": {}}}'
# {"server": "linear", "connected": false, "authorization": {"url": "https://…"}}
```

For each `server/*` in an agent's tools, the first match is used:

1. A server the agent's owner added.
2. A server the agent's org added.
3. A server in `config.yaml` for the agent's org.

`servers/*` includes every server the agent's owners add. `wardrik agent show` lists a server with
no tools yet as `missing`.

## Details

- The model sees each tool as `server__tool`, such as `linear__search_issues`.
- A command inherits the daemon's environment, plus its `env`. The systemd service has a minimal
  `PATH`, so use the program's full path.
- In Docker, the program must be in the image. Build `FROM ghcr.io/wardrik-dev/wardrik:0.1.0-rc.2`.
- `prefix`, `timeout`, `max_result_bytes` and `cost` are in [`config.yaml` › mcp](/reference/config/#mcp).
- A server that's down has no tools. The daemon reconnects with backoff up to a minute.
- A server added at runtime must be `https` at a public address, unless `allow_private_urls: true`.
- `wardrik reload` rereads agent files, not `config.yaml`.
