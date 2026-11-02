---
title: Connect MCP servers
description: "Give agents the tools of an MCP server, from config.yaml or added while the daemon runs, and decide which calls need a person."
sidebar:
  order: 1
---

Name MCP servers in `config.yaml`. A server runs as a command, or is reached over HTTP:

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
echo "$LINEAR_TOKEN" | wardrik vault put LINEAR_TOKEN --for header   # so the file holds no secret
systemctl --user restart wardrik
wardrik doctor                                                       # checks each server
```

Give an agent the tools in its file:

```yaml
tools: [linear/*, notes/*]
```

- A policy names one tool as `linear/search_issues`.
- `only` and `except` narrow what a server offers.
- `headers` and `env` are the deployment's credentials, shared by every org the server serves. To
  call a server as each person, give it a `credential`. See [Connect accounts](/build/accounts/).
- Every key is in [`config.yaml` › mcp](/reference/config/#mcp).

## Which calls need a person

A tool the server doesn't mark read-only waits on a person, unless a policy allows it:

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
- Without `trusted: true`, a server's answers are [content from outside](/concepts/outside-content/).

See [Gated tools](/concepts/policy/#gated-tools).

## Which orgs a server serves

A server serves the deployment's org. List it under `orgs` for others:

```yaml
orgs:
  "*":
    mcp: [docs]          # every org
  globex:
    mcp: [globex-crm]    # globex alone
```

## Servers people add

An org or a person adds a server for their own agents, with no change to `config.yaml`:

```sh
wardrik server add linear --url https://mcp.linear.app/mcp --oauth --user maria
wardrik server ls --user maria
wardrik server rm linear --user maria
```

Its agents sign in with one of:

- `--oauth`, with a `--scope` for each scope: the owner signs in in a browser. `server add` prints
  where.
- `--secret NAME`: a secret the owner sealed `--for header`.
- neither: nothing.

Over HTTP:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/owners/acme%2F%40maria/servers \
  -d '{"name": "linear", "url": "https://mcp.linear.app/mcp", "auth": {"oauth": {}}}'
# {"server": "linear", "connected": false, "authorization": {"url": "https://…"}}
```

For each `server/*` an agent names, the nearest wins:

1. The server its owner added.
2. The server its org added.
3. The server `config.yaml` names for its org.

`servers/*` gives an agent every server its owners add. `wardrik agent show` lists a named server
that offers nothing yet as `missing`.

## Details

- The model sees each tool as `server__tool`, as `linear__search_issues`.
- `prefix` renames a server's tools for the model and policies.
- A command inherits the daemon's environment, plus its `env`. The service runs with systemd's
  `PATH`: name a program by its full path.
- In Docker, the program must be in the image: build `FROM ghcr.io/wardrik-dev/wardrik:0.1.0-rc.2`.
- `timeout` is seconds a call may take, 60 unless set. `max_result_bytes` caps what the model gets,
  128 KB unless set.
- A server that's down offers no tools. The daemon reconnects, waiting up to a minute between tries.
- A server people add must be `https` at a public address, unless `allow_private_urls: true`.
- `wardrik reload` reads agent files again, never `config.yaml`.
