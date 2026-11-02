---
title: Security
description: "The daemon's ports and access, where secrets are stored, and what agents are allowed to do."
sidebar:
  order: 4
---

The daemon runs as one OS user. Any process running as that user can read the store and use its
credentials. Don't share the host with untrusted accounts.

## Ports

| | Port | Interface | Access |
| --- | --- | --- | --- |
| The HTTP API | 4747 | loopback, or `http.ip` | requests with a [token](/run/orgs/#tokens), and the [public paths](/run/public-address/#exposed-paths) |
| Erlang distribution | random | all | anyone with the cookie |
| epmd | 4369 | all | anyone; returns the node name and port |

- The HTTP API is plain HTTP. Over a network, put a TLS-terminating proxy in front.
- Block 4369 and the distribution port at the firewall.

## Distribution

`wardrik stop` and `wardrik pid` connect to the node with the cookie in
`~/.local/share/wardrik/cookie`. Anyone with the cookie and network access to the port can run
arbitrary code on the node. `RELEASE_COOKIE` overrides the cookie, and `WARDRIK_COOKIE_FILE` sets
the file path.

## Secrets

- `${NAME}` in `config.yaml` resolves from the environment, the env file, or the vault, so the
  file contains no secrets.
- The vault encrypts secrets and accounts with AES-256-GCM. Back up its key separately from the
  store. See [the vault](/build/vault/).
- `~/.config/wardrik/env` contains keys. `wardrik doctor` fails if other users can read it.
- `~/.local/share/wardrik/cli_token` is the admin token, with full access.
- An MCP server run as a command runs as the daemon's user, with its environment. Run only trusted
  servers.

## Agent permissions

A policy checks each call. After a turn reads content from outside, its gated tools need approval.
See [Policy](/concepts/policy/) and [Content from outside](/concepts/outside-content/).

URLs added at runtime, for MCP servers, webhooks and OAuth apps, must be `https` at a public
address. `allow_private_urls: true` removes that check. For local development only.

## Files

| Directory | Contents | Readable by |
| --- | --- | --- |
| `~/.config/wardrik` | `config.yaml`, `agents/`, `policies/`, `env` | as you set it; `env` is mode `600` |
| `~/.local/share/wardrik` | the store, the cookie, `vault_key`, `cli_token` | the daemon's user |
| `~/.local/state/wardrik` | logs | the daemon's user |

`WARDRIK_CONFIG_DIR`, `WARDRIK_DATA_HOME` and `WARDRIK_STATE_DIR` override them.

## Report a vulnerability

Report it privately, from the repository's Security tab under **Report a vulnerability**.
