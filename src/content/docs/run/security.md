---
title: Security
description: "What the daemon listens on, who gets in, where its secrets live, and what agents may do."
sidebar:
  order: 4
---

The daemon runs as one user. Whatever can act as that user can do what Wardrik does: read its
store, use its credentials, run its agents' tools. Run it on a host or container you don't share
with accounts you don't trust.

More on who reaches what:

- [Tokens](/run/tokens/): what each HTTP API token may reach and do, and when it expires.
- [Orgs](/run/orgs/): how agents of different orgs and users are kept apart.

## What listens

| | Port | Listens on | Who gets in |
| --- | --- | --- | --- |
| The HTTP API | 4747 | loopback, or `http.ip` | a request with a [token](/run/tokens/), and the [public paths](/run/public-address/#what-is-exposed) |
| Erlang distribution | one the node picks | every interface | anything holding the cookie |
| epmd | 4369 | every interface | anyone; it names the node and its port |

The HTTP API speaks plain HTTP. To reach it across a network, put a proxy in front that ends TLS. A
token sent over plain HTTP can be read on the way. See [A public address](/run/public-address/).

## Distribution

`wardrik stop` and `wardrik pid` reach the node over Erlang distribution. It checks only the cookie:
64 random hex characters in `~/.local/share/wardrik/cookie`, readable by the daemon's user alone.

Anything that holds the cookie and reaches the port can run any code on the node. The traffic isn't
encrypted. Block port 4369 and the distribution port at the host's firewall, so only the machine
itself reaches them.

## The `wardrik` command

The `wardrik` command reaches the daemon over the HTTP API, not distribution. Each time the daemon
starts, it writes an owner token on every resource to `~/.local/share/wardrik/cli_token`, readable
by its user alone. Anyone who reads that file can do anything the daemon can.

## Secrets

- **Keys and tokens** come from the environment, the env file, or the vault. `${NAME}` in
  `config.yaml` reads one, so the file holds no secret.
- **Credentials and OAuth tokens** are sealed with AES-256-GCM before they're stored. Keep the
  vault's key apart from the store: set `WARDRIK_VAULT_KEY`, or `vault.keys`. See
  [Connect accounts](/build/accounts/).
- **The env file**, `~/.config/wardrik/env`, holds keys. Keep it readable by you alone.
  `wardrik doctor` fails while others can read it.

## What agents may do

An agent can do what its tools can do, and anything a tool returns can steer the model. A policy
decides each call, whoever asked for it. Once a run reads outside content, its gated tools wait for
a person. See [Policy](/concepts/policy/) and [Content from outside](/concepts/outside-content/).

## Report a vulnerability

Report it privately, through the repository's Security tab under **Report a vulnerability**, not in
a public issue.

## Details

### In a container

Inside a container, the API must listen on every interface, `http.ip: 0.0.0.0`, since the
container's loopback is reachable from nowhere else. The ports you publish decide who reaches it:
`-p 127.0.0.1:4747:4747` keeps the API to the host. Don't publish 4369 or the distribution port.

### The cookie

The daemon makes the cookie at first start. `RELEASE_COOKIE` sets another, and
`WARDRIK_COOKIE_FILE` moves the file.

### More on secrets

- `vault`, `http` and `storage` in `config.yaml` read the environment and the env file alone.
- Without a configured key, the daemon makes `vault_key` beside the store as it first starts.
  Anyone who can read both reads every secret.
- Every `wardrik` command, and the daemon, sets each variable in the env file that its environment
  doesn't. So the daemon's environment holds the env file's keys.
- An MCP server run as a command starts with the daemon's environment, its own `env` beside it. It
  runs as the daemon's user, so it can read what the daemon can. Run only servers you trust.

### Files

| Directory | What it holds | Who can read it |
| --- | --- | --- |
| `~/.config/wardrik` | `config.yaml`, `agents/`, `policies/`, `env` | as you set it; `env` you alone |
| `~/.local/share/wardrik` | the store, the cookie, `vault_key`, `cli_token` | the daemon's user |
| `~/.local/state/wardrik` | logs | the daemon's user |

`WARDRIK_CONFIG_DIR`, `WARDRIK_DATA_HOME` and `WARDRIK_STATE_DIR` move them. The daemon writes
`cookie`, `vault_key`, `cli_token` and `env` readable by its user alone. Set the directories'
modes yourself.

### Calls after outside content

An agent that reads outside content, reaches what is private and changes things needs a person for
all three. Once a run carries the `outside` label, its gated tools wait for a person, unless an
`allow_after` rule names them. MCP servers' tools are gated unless marked read-only, or the
server's `gated` says otherwise.
