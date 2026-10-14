---
title: Security
description: What the daemon listens on, who it lets in, how tokens reach agents, and where its secrets are kept.
sidebar:
  order: 4
---

The daemon runs as one user, and whatever can act as that user can do what Wardrik does: read its
store, use its credentials and run its agents' tools. Run it on a host, or in a container, that you
do not share with accounts you do not trust.

## What listens

Everything listens on loopback unless you say otherwise.

| | Port | Who gets in | Beyond loopback |
| --- | --- | --- | --- |
| The HTTP API | 4747 | a request with a [token](#tokens) | `http.ip`, or `WARDRIK_HTTP_IP` |
| The terminal client, over SSH | 2222 | a key in `ssh/authorized_keys` | `ssh.ip`, or `WARDRIK_SSH_IP` |
| Erlang distribution, and epmd | 4369, and one it chooses | anything holding the cookie | `WARDRIK_DIST_INTERFACE`, with `WARDRIK_DIST_EXPOSED=1` |
| The OAuth callback | 4599 | a provider sending a browser back | `oauth.redirect.ip`, behind HTTPS; see [A public address](/run/public-address/) |

The HTTP API speaks plain HTTP, and the terminal client SSH. To reach the API across a network, put
a proxy in front of it that ends TLS: a token sent over plain HTTP can be read on the way.

The Docker image listens for the API and the terminal client on every interface of the container,
since its loopback is reachable from nowhere else, so the ports it is run with decide who reaches
them: `-p 127.0.0.1:4747:4747` keeps the API to the host. Distribution stays inside the container.

### Distribution

The `wardrik` command and `wardrik remote` reach the daemon with Erlang distribution, as the nodes
of a cluster reach each other. It checks one thing, the cookie: 48 random characters in
`~/.local/share/wardrik/cookie`, readable by the daemon's user only. Anything holding the cookie
that reaches the port can run any code on the node, and what distribution sends is not encrypted.
An account on the host that can list processes can read the cookie from a command line.

A cluster across machines listens beyond loopback, which the daemon refuses unless
`WARDRIK_DIST_EXPOSED=1` is set beside `WARDRIK_DIST_INTERFACE`. Do it only on a private network that
authenticates its members and encrypts their traffic, such as Tailscale or WireGuard, and never on
a public interface. See [Run a cluster](/run/cluster/#on-several-machines).

## Tokens

Every HTTP request presents a token that `wardrik token create` made:

```sh
wardrik token create NAME (--scope PREFIX | --all) [--can ACTIONS] [--policy NAME | --unlimited]
```

- **`--scope`** is the agents it reaches: `acme/`, acme's own agents and none of its users';
  `acme/@jon/`, jon's; `acme/*`, acme and every one of its users'; or one agent, `acme/@jon/triage`.
  `--all` reaches every agent. An agent outside the scope is answered as one that does not exist.
- **`--can`** is what it may do, some of `read`, `message`, `decide`, `define` and `serve`, and all
  of them unless it says fewer. An action it may not take is refused with `403`.
- **`--policy`** holds every agent the token defines to a policy of `policies/`, ahead of the
  definition's own, so a definition can narrow what the policy allows and never widen it.
  `--unlimited` says the agents it defines are held to their own policies alone. A token that can
  `define` needs one or the other.

| Action | What it reaches |
| --- | --- |
| `read` | listing agents, their snapshots and their events |
| `message` | sending messages, and stopping a turn |
| `decide` | approving and denying waiting calls, and their authorization links |
| `define` | putting and removing agents and triggers |
| `serve` | offering tools as a [worker](/build/tool-workers/) |

```sh
wardrik token create ci --scope acme/ --policy careful
wardrik token create watcher --scope acme/@ops/ --can read
wardrik token create shop --scope acme/ --can serve
wardrik token list
wardrik token revoke 3f9a61c0d4e2
```

The token is printed once, and the store keeps only its SHA-256. It does not expire: revoke one
that is no longer needed. Revoking refuses it at once, and closes the event streams and worker
connections open on it, on every node the revocation reaches, and within 15 seconds on one it does
not. An agent a revoked token defined keeps running, under the policy it was defined with.

## Orgs

Every agent belongs to an [org](/concepts/agents/#keys-and-orgs), and an org is the boundary
between agents. Within an org, an agent works for the org or for one of its users, and each is
apart: what reaches the org's agents reaches none of its users', and what reaches one user's
reaches neither the org's nor another user's, unless it names the whole tenant, `acme/*`. What
belongs to an org, or to one of its users, is kept to their agents:

- tokens scoped to the org, to one of its users, or to the tenant;
- shared trees named for the org or one of its users, and those `workspace.shared` in
  `config.yaml` shares with others;
- the vault's credentials put for the org or one of its users, and the accounts they connect: an
  agent reads its own owner's alone, never its org's for a user's agent;
- what people in a channel may read and message: the agents of the orgs it offers, none of their
  users' but those whose files name the channel;
- MCP servers and notice targets, which serve the deployment's org unless `config.yaml` names
  others.

Some things are the deployment's, whatever the org:

- `policies/`, which any agent file can name;
- the vault's credentials put for the deployment, which an agent reads only where `vault.shared`
  names them;
- the credentials in an MCP server's `headers` or `env`, used for every org the server serves;
- the terminal client, whose keys reach every org's agents.

## The terminal client

The terminal client is served once `~/.config/wardrik/ssh/authorized_keys` lists a key, and a key it
lists reaches every agent and everything the client does, including removing agents. A key logs in
only under the names it is listed for, by its `principals` option, or else its comment's name before
any `@`. Other options on a key, such as `from=` and `command=`, are not applied. There are no passwords, and no commands,
subsystems or forwarding: only the client. See [The terminal client](/build/tui/).

## Secrets

- **Provider keys and tokens** come from the environment, and, for a name it does not set, from the
  vault, which `wardrik vault put` seals. `${NAME}` in `config.yaml` reads one, so the file need
  hold no secret; `storage`, `cluster`, `http` and `vault` read the environment alone. A key from the vault
  goes into the daemon's settings, never its environment. Every `wardrik` command reads
  `~/.config/wardrik/env`; keep it readable by the daemon's user only, which `wardrik doctor` checks.
- **Credentials and OAuth tokens** are sealed with AES-256-GCM by the vault, before they are stored.
  Where no key is configured, the first `wardrik vault put` makes `vault_key` beside the store, and
  anyone who can read both reads every secret; `WARDRIK_VAULT_KEY` or `vault.keys` keeps the key
  apart. The daemon never puts it in its environment. See [Connect accounts](/build/accounts/).
- **An MCP server run as a command** is given only `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LOGNAME`,
  `PATH`, `SHELL`, `TERM`, `TMPDIR` and `USER` of the daemon's environment, beside what its own
  config sets, so the keys the daemon holds stay with it. It runs as the daemon's user, so it can
  read what the daemon can.

## Files

| Directory | What it holds | Who can read it |
| --- | --- | --- |
| `~/.config/wardrik` | `config.yaml`, agent and policy files, `ssh/authorized_keys`, `env` | as you set it |
| `~/.local/share/wardrik` | the store, the cookie, the SSH host key, the vault's key | the daemon's user |
| `~/.local/state/wardrik` | logs | the daemon's user |

The daemon writes with umask 077, and makes its data and state directories private again each time
it starts.

## What agents may do

What an agent can do is what its tools can do, and anything a tool returns reaches the model and
can steer it. A policy decides what an agent's calls may do, whoever asked for them. An agent may
read content from outside, reach what is private, or change things, and a person decides where it
would do all three: once its conversation holds content from outside, its gated tools wait on a
person, unless an `allow_after` rule the operator wrote names them, until `wardrik clear`
empties it. MCP servers' and tool workers' tools are gated unless they mark them read-only. See
[Policy and approvals](/concepts/policy/).

## Reporting a vulnerability

Report it privately, through the repository's Security tab under **Report a vulnerability**, rather
than in a public issue.
