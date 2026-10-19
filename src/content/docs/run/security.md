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

- [Tokens](/run/tokens/): what each HTTP API token may reach and do, and when tokens expire.
- [Orgs](/run/orgs/): how agents of different orgs and users are kept apart.

## What listens

Everything listens on loopback unless you say otherwise.

| | Port | Who gets in | Beyond loopback |
| --- | --- | --- | --- |
| The HTTP API | 4747 | a request with a [token](/run/tokens/), or a browser a provider sends back to `/oauth/` | `http.ip`, or `WARDRIK_HTTP_IP`, behind HTTPS; see [A public address](/run/public-address/) |
| The terminal client, over SSH | 2222 | a key in `ssh/authorized_keys` | `ssh.ip`, or `WARDRIK_SSH_IP` |
| Erlang distribution, and epmd | 4369, and one it chooses | anything holding the cookie | `WARDRIK_DIST_INTERFACE`, with `WARDRIK_DIST_EXPOSED=1` |

The HTTP API speaks plain HTTP. To reach it across a network, put a proxy in front that ends TLS; a
token sent over plain HTTP can be read on the way.

## Distribution

The `wardrik` command and `wardrik remote` reach the daemon over Erlang distribution, as cluster
nodes reach each other. It checks only the cookie: 48 random characters in
`~/.local/share/wardrik/cookie`, readable by the daemon's user.

Anything holding the cookie that reaches the port can run any code on the node, and the traffic
isn't encrypted. Listen beyond loopback only on a private network that authenticates and encrypts,
such as Tailscale or WireGuard. See [Run a cluster](/run/cluster/#on-several-machines).

## The terminal client

The client is served once `~/.config/wardrik/ssh/authorized_keys` lists a key. A listed key reaches
every agent and everything the client does, including removing agents. See
[The terminal client](/build/tui/).

## Tokens expire

Every token expires. A token for the HTTP API lasts 90 days, `tokens.expires.api`, then is refused.
One the daemon issues, as a shell's or someone's in a channel, lasts 12 hours,
`tokens.expires.session`, then is refreshed as it is used, holding only what `config.yaml` gives
now, so access you take away is gone at its next use. See [Tokens](/run/tokens/#when-it-expires).

## Secrets

- **Keys and tokens** come from the environment, or from the vault for names it doesn't set.
  `${NAME}` in `config.yaml` reads one, so the file holds no secret.
- **Credentials and OAuth tokens** are sealed with AES-256-GCM before they're stored. Keep the
  vault's key apart from the store with `WARDRIK_VAULT_KEY` or `vault.keys`. See
  [Connect accounts](/build/accounts/).
- **An MCP server run as a command** gets only a short list of the daemon's environment, so the
  daemon's keys stay with it.

## What agents may do

An agent can do what its tools can do, and anything a tool returns can steer the model. A policy
decides each call, whoever asked for it. Once an agent has read outside content, its gated tools
wait for a person. See [Policy](/concepts/policy/) and
[Content from outside](/concepts/outside-content/).

## Report a vulnerability

Report it privately, through the repository's Security tab under **Report a vulnerability**, not in
a public issue.

## Details

### Docker

The image listens for the API and the terminal client on every interface of the container, since
its loopback is reachable from nowhere else. The ports you publish decide who reaches them:
`-p 127.0.0.1:4747:4747` keeps the API to the host. Distribution stays inside the container.

### The cookie

An account on the host that can list processes can read the cookie from a command line. A cluster
across machines is refused unless `WARDRIK_DIST_EXPOSED=1` is set beside `WARDRIK_DIST_INTERFACE`.
Never listen on a public interface.

### The terminal client's keys

A key logs in only under the names it's listed for: its `principals` option, or else its comment's
name before any `@`. Other key options, such as `from=` and `command=`, aren't applied. There are no
passwords, and no commands, subsystems or forwarding: only the client.

### More on secrets

- `storage`, `cluster`, `http` and `vault` read the environment alone.
- A key from the vault goes into the daemon's settings, never its environment.
- Every `wardrik` command reads `~/.config/wardrik/env`. Keep it readable by the daemon's user only;
  `wardrik doctor` checks.
- Without a configured key, the first `wardrik vault put` makes `vault_key` beside the store. Anyone
  who can read both reads every secret. The daemon never puts the key in its environment.
- An MCP server run as a command gets only `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LOGNAME`, `PATH`,
  `SHELL`, `TERM`, `TMPDIR` and `USER`, beside its own config. It runs as the daemon's user, so it
  can read what the daemon can.

### Files

| Directory | What it holds | Who can read it |
| --- | --- | --- |
| `~/.config/wardrik` | `config.yaml`, agent and policy files, `ssh/authorized_keys`, `env` | as you set it |
| `~/.local/share/wardrik` | the store, the cookie, the SSH host key, the vault's key | the daemon's user |
| `~/.local/state/wardrik` | logs | the daemon's user |

The daemon writes with umask 077, and makes its data and state directories private again at each
start.

### Calls after outside content

An agent that reads outside content, reaches what is private and changes things needs a person for
all three. Its gated tools wait unless an `allow_after` rule the operator wrote names them, until
`wardrik clear` empties its conversation. MCP servers' and tool workers' tools are gated unless
marked read-only.
