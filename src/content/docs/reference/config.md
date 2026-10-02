---
title: "config.yaml"
description: "Where the daemon keeps things, and what config.yaml configures."
editUrl: false
sidebar:
  order: 2
---

<!-- Written by mix wardrik.docs from WardrikDaemon.Config. Edit it there, not here. -->

Where the daemon keeps things, and what `config.yaml` configures.

The daemon follows the XDG base directories, so what a person writes stays
apart from what the daemon writes:

| Directory | Default | What it holds |
| --- | --- | --- |
| `WARDRIK_CONFIG_DIR` | `$XDG_CONFIG_HOME/wardrik`, `~/.config/wardrik` | `config.yaml` or `config.yml`, and `agents/`; see `WardrikDaemon.AgentFile` |
| `WARDRIK_DATA_DIR` | `$XDG_DATA_HOME/wardrik/store`, `~/.local/share/wardrik/store` | the store |
| `WARDRIK_COOKIE_FILE` | `$XDG_DATA_HOME/wardrik/cookie`, `~/.local/share/wardrik/cookie` | the node's distribution cookie |
| `WARDRIK_DATA_HOME` | `$XDG_DATA_HOME/wardrik`, `~/.local/share/wardrik` | `vault_key`, the vault's key where none is configured; see `WardrikDaemon.VaultKey` |
| `WARDRIK_STATE_DIR` | `$XDG_STATE_HOME/wardrik`, `~/.local/state/wardrik` | `log/wardrik.log`, and `log/mcp.log` for what MCP commands write to stderr |

## config.yaml

The file is `config.yaml`, or `config.yml`; a directory holding both is
refused, since one of them would go unread.

    org: acme

    mcp:
      linear:
        url: https://mcp.linear.app/mcp
        headers:
          authorization: Bearer ${LINEAR_TOKEN}
      notes:
        command: npx
        args: [-y, "@modelcontextprotocol/server-filesystem", /srv/notes]
        only: [read_file, list_directory]
      github:
        url: https://api.githubcopilot.com/mcp/
        credential: github
      docs:
        url: https://docs.example.com/mcp
        org: "*"

    oauth:
      providers:
        github:
          resource: https://api.githubcopilot.com/mcp/
          issuer: https://github.com/login/oauth
          client_id: ${GITHUB_CLIENT_ID}
          client_secret: ${GITHUB_CLIENT_SECRET}
          scopes: [repo]

    vault:
      keys: ["${WARDRIK_VAULT_KEY}"]

    notify:
      ops:
        slack:
          channel: "#ops"
          token: ${SLACK_BOT_TOKEN}
          app_token: ${SLACK_APP_TOKEN}
          approvers: [U012ABCDEF]
      audit:
        webhook:
          url: https://hooks.example.com/wardrik
          secret: ${WARDRIK_WEBHOOK_SECRET}

    storage:
      s3:
        bucket: wardrik
        endpoint: https://<account>.r2.cloudflarestorage.com
        region: auto
        access_key_id: ${R2_ACCESS_KEY_ID}
        secret_access_key: ${R2_SECRET_ACCESS_KEY}

It is YAML 1.2, the same YAML an agent file's frontmatter is written in.

`${NAME}` in any string is replaced with that environment variable, or,
where the environment does not set it, with the deployment's secret of that
name in the vault, which `wardrik vault put NAME` seals. Either way the file
itself need hold no secret. `storage`, `cluster` and `vault` read the
environment alone: the store holds the vault, the cluster is read as the
node boots, before the vault can be, and the vault cannot unlock itself.

`org` is the deployment's org: the one an agent belongs to where its file
names none, and the one the CLI finds an agent in when it is named without
an org. It is `default` unless set. See `Wardrik.Fleet`.

An MCP server and a notify target each serve one org's agents, the
deployment's own, unless its `org` names another, a list of them, or `*`
for every org. An agent cannot reach a server, or route its notices to a
target, that is not its org's.

A server with `command` is started as a command, with `args`, `env` and
`cwd` beside it; one with `url` is reached over HTTP, with `headers`. Either
takes `only`, `except`, `prefix`, `timeout` in seconds, `max_result_bytes`,
`credential`, the name of the credential it is reached with, along with
`credential_header`, `credential_scheme` and `credential_env`, `gated`,
the tools whose calls wait on a person unless a rule allows them by name,
every tool the server does not mark read-only unless set, and
`trusted: true` for a server whose answers are the deployment's own, so a
call to it does not taint its run. See `WardrikMCP.Server`.

A credential is kept in the vault, sealed, and found for each call the most
specific first: the agent's user's, sealed with `wardrik vault put NAME
--user USER`; its org's, with `--org ORG`; then the deployment's, with
`wardrik vault put NAME`. Where none holds it and `oauth` has a provider of
the same name, the agent's user, or its org where it has no user, is asked
to connect an account, which is kept in the vault from then on.

`oauth` takes `client`, `redirect` and `providers`, as `WardrikOAuth.Config`
describes them. `vault` takes `keys`, as `WardrikVault` does; without them,
or `WARDRIK_VAULT_KEY`, the vault's key is `vault_key` in the data home,
which the first `wardrik vault put` asks to make. `ssh` takes
`port` and `ip`, as `WardrikDaemon.SSH` does, and so does `http`, as `WardrikHTTP`
does, with `trusted_workers: true` where tool workers' answers are the
deployment's own.

`cluster` takes `nodes`, or `dns` and `size`, as `WardrikDaemon.Cluster`
describes them, and joins this daemon to others.

`storage` names the store everything is kept in, one of:

  * `postgres`, with `url`, a `postgres://` URL, as `WardrikEcto.Store`
    takes it: the daemon connects with a repo of its own and creates the
    table as it starts.
  * `s3`, with `bucket`, `endpoint`, `access_key_id` and `secret_access_key`,
    and optionally `region` and `prefix`, as `WardrikS3.Store` takes them.

Without `storage`, the store is `Wardrik.Store.EKV`, on the node's disk under
`WARDRIK_DATA_DIR`. A release reads `storage` and `cluster` as it boots,
before anything starts, and the rest once the store runs; see `boot/1`.

`notify` names targets an agent file's `notify` routes to, each one
`slack`, with `channel`, `token`, and optionally `app_token` and
`approvers`, as `WardrikNotify.Slack` takes them; or `webhook`, with `url` and
optionally `secret`, as `WardrikNotify.Webhook` takes them.

`read/1` refuses a file with a variable that is not set, a key nothing takes,
a server that is neither a command nor a URL, or a server whose name or
`prefix` holds `__`, and says where.
