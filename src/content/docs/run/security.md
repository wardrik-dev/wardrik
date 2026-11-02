---
title: Security
description: "What the daemon listens on, who gets in, where its secrets live, and what agents may do."
sidebar:
  order: 4
---

The daemon runs as one user. Anything that can act as that user can read its store and use its
credentials. Don't share the host with accounts you don't trust.

## What listens

| | Port | Listens on | Who gets in |
| --- | --- | --- | --- |
| The HTTP API | 4747 | loopback, or `http.ip` | a request with a [token](/run/orgs/#tokens), and the [public paths](/run/public-address/#what-is-exposed) |
| Erlang distribution | one the node picks | every interface | anything holding the cookie |
| epmd | 4369 | every interface | anyone; it names the node and its port |

- The HTTP API is plain HTTP. Across a network, put a proxy in front that ends TLS.
- Block 4369 and the distribution port at the firewall.

## Distribution

`wardrik stop` and `wardrik pid` reach the node with the cookie in
`~/.local/share/wardrik/cookie`. Anything holding the cookie, and reaching the port, can run any
code on the node. `RELEASE_COOKIE` sets another cookie, and `WARDRIK_COOKIE_FILE` moves the file.

## Secrets

- `${NAME}` in `config.yaml` reads the environment, the env file, or the vault. The file holds no
  secret.
- The vault seals secrets and accounts with AES-256-GCM. Keep its key apart from the store's
  backups. See [the vault](/build/vault/).
- `~/.config/wardrik/env` holds keys. `wardrik doctor` fails while others can read it.
- `~/.local/share/wardrik/cli_token` is the admin's token. Whoever reads it can do anything.
- An MCP server run as a command runs as the daemon's user, with its environment. Run only servers
  you trust.

## What agents may do

A policy decides each call. Once a run reads content from outside, its gated tools wait for a
person. See [Policy](/concepts/policy/) and [Content from outside](/concepts/outside-content/).

URLs people add, for MCP servers, webhooks and OAuth apps, must be `https` at a public address.
`allow_private_urls: true` lifts that, for local development only.

## Files

| Directory | Holds | Who can read it |
| --- | --- | --- |
| `~/.config/wardrik` | `config.yaml`, `agents/`, `policies/`, `env` | as you set it; `env` you alone |
| `~/.local/share/wardrik` | the store, the cookie, `vault_key`, `cli_token` | the daemon's user |
| `~/.local/state/wardrik` | logs | the daemon's user |

`WARDRIK_CONFIG_DIR`, `WARDRIK_DATA_HOME` and `WARDRIK_STATE_DIR` move them.

## Report a vulnerability

Report it privately, through the repository's Security tab under **Report a vulnerability**.
