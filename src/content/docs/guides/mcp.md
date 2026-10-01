---
title: Connect MCP servers
description: Give agents the tools of an MCP server, run as a command or reached over HTTP, and decide which of them they may call.
sidebar:
  order: 2
---

An MCP server's tools are named in `config.yaml`, under `mcp`, and an agent file gives them to an
agent. A server is run as a command, or reached over HTTP:

```yaml title="~/.config/wardrik/config.yaml"
mcp:
  linear:
    url: https://mcp.linear.app/mcp
    headers:
      authorization: Bearer ${LINEAR_TOKEN}
  notes:
    command: npx
    args: [-y, "@modelcontextprotocol/server-filesystem", /srv/notes]
    only: [read_file, list_directory]
```

`${NAME}` is read from the daemon's environment, so the file need hold no secret. Under the service,
put the variable in `~/.config/wardrik/env`.

The daemon reads `config.yaml` when it starts, so restart it after changing one:

```sh
systemctl --user restart wardrik    # or: wardrik stop, then wardrik start
wardrik doctor                      # each server, and whether it can be reached
```

`wardrik reload` reads agent and policy files only.

## Giving an agent the tools

An agent file names a server's tools as `server/*`, by the name `config.yaml` gives the server:

```yaml
tools: [linear/*, notes/*]
```

`*` gives an agent the tools of every server it can reach, with everything else. A file cannot
name one tool of a server: narrow what the server offers with `only` or `except` in `config.yaml`,
by the names the server gives its tools, or decide which calls may run with a
[policy](/concepts/policy/).

The model sees each tool as `server__tool`, such as `linear__search_issues`, with the server's own
description and JSON Schema. A policy names it as `linear/search_issues`, or every tool of the
server as `linear/*`. `prefix` gives the server's tools another name than the server's, for the
model and for policies alike, while an agent file still names the server by its own.

## Which orgs a server serves

A server serves the agents of the deployment's [org](/concepts/agents/#keys-and-orgs) unless its
`org` names others, or `*` for every org:

```yaml
org: acme

mcp:
  linear:                                  # acme's agents
    url: https://mcp.linear.app/mcp
  globex-crm:
    url: https://crm.globex.example/mcp
    org: globex                            # globex's agents alone
  docs:
    url: https://docs.example.com/mcp
    org: "*"                               # every org's
```

An agent file that names a server its org is not served by does not read, and says why;
`wardrik status` lists it. A call from another org's agent is refused too, whatever it was given.

The credentials in a server's `headers` or `env` are the deployment's, so a server that every org
shares reaches the service the same way for all of them. Give each org a server of its own, or
reach it as each user with [Connect accounts](/guides/accounts/).

## A server run as a command

`command` is the program, with `args`, `env` and `cwd` beside it. The command sees only a few of the
daemon's environment variables, `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LOGNAME`, `PATH`, `SHELL`,
`TERM`, `TMPDIR` and `USER`, with the `env` it is given, so the keys the daemon holds stay with the
daemon:

```yaml
mcp:
  github:
    command: github-mcp-server
    args: [stdio]
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_TOKEN}
```

What a command writes to its standard error is kept in `~/.local/state/wardrik/log/mcp.log`.

The service runs with systemd's `PATH`, not your shell's, so a program installed under your home
directory, as `npx` often is, may be found by `wardrik doctor` and not by the service. Name such a
program by its full path. In Docker, a command needs its program in the image: build your own
`FROM ghcr.io/wardrik-dev/wardrik`.

## A server reached over HTTP

`url` is the server's Streamable HTTP endpoint, as it publishes it, with `headers` to send with
every request:

```yaml
mcp:
  linear:
    url: https://mcp.linear.app/mcp
    headers:
      authorization: Bearer ${LINEAR_TOKEN}
```

A key in `headers` is the deployment's own: every agent reaches the server as the deployment. To
have each user connect their own account instead, see [Connect accounts](/guides/accounts/).

## What a server's tools may do

- `gated` lists the tools whose calls wait on a person unless a policy's `allow` rule names them, or
  is `true` for all of them. A name ending in `*` names every tool it begins. See
  [Gated tools](/concepts/policy/#gated-tools).
- `trusted: true` says the server's answers are the deployment's own. Without it, what a server
  returns is content from outside, and a turn that has read it waits on a person before a gated
  tool's call runs. See [Content from outside](/concepts/policy/#content-from-outside).

```yaml
mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    credential: user:github
    gated: [create_*, merge_*, delete_*]
  runbooks:
    url: http://runbooks.internal:8080/mcp
    trusted: true
```

## Limits

- `timeout` is how many seconds a call may take, 60 unless set.
- `max_result_bytes` is how much of a call's result the model is given, 128 KB unless set. A longer
  one is cut, and the model is told it was.

A result's structured content is given to the model where the server returns some, and its text
otherwise. An image in a result is not read: the model is told there was one.

## When a server is down

A server that is down offers no tools, and the agents with it carry on without them. The daemon
connects again by itself, waiting longer each time, up to a minute between tries. A server that
says its tools have changed is asked for them again.

A call stopped before it answers, by a timeout or a stopped turn, is cancelled on the server too.
A server's progress reaches the event stream as `tool_call.progress`.
