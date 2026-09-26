# Security

## Reporting a vulnerability

Report it privately, through this repository's Security tab under "Report a
vulnerability", rather than in a public issue.

## The model

The daemon runs as one user, and whatever can act as that user can do what
Tars does: read its store, use its credentials, and run its agents' tools. Run
it on a host, or in a container, that you do not share with accounts you do
not trust.

### Distribution

The node's Erlang distribution listens on loopback, and so does epmd when the
node starts it. The CLI (`tars status`, `ask`, `approve` and the rest) and
`tars remote` reach the node that way, as do the other nodes of a cluster.

Distribution checks one thing: the cookie, 48 random characters written to
`~/.local/share/tars/cookie` on first start, readable by the daemon's user
only. The release hands the cookie to each Erlang VM on its command line, and
`bin/tars` to `erl_call` on its, so any account on the host that can list
processes can read it, and anything that holds the cookie and reaches the port
can run any code on the node as the daemon's user. What distribution sends
between nodes is not encrypted.

`TARS_DIST_INTERFACE` moves distribution beyond loopback, for a cluster that
spans hosts. It is refused unless `TARS_DIST_EXPOSED=1` is set beside it, and a
node started that way says so as it starts. Use it only on a private network
that authenticates its members and encrypts their traffic, such as Tailscale
or WireGuard, and never on a public interface.

### Files

| Directory | What it holds | Who can read it |
| --- | --- | --- |
| `~/.config/tars` | `config.yaml`, agent and policy files, `ssh/authorized_keys` | as its owner sets it; `${NAME}` in `config.yaml` reads a value from the environment, so the file need hold no secret |
| `~/.local/share/tars` | the store, with every agent's conversation, the ledger, budgets and sealed tokens; the cookie; the SSH host key | the daemon's user |
| `~/.local/state/tars` | logs | the daemon's user |

The release sets umask 077, so what the node and the commands it starts write
is readable by the daemon's user only, and it makes the data and state
directories private again on every start.

### SSH

Once `~/.config/tars/ssh/authorized_keys` exists, the daemon serves the TUI
over SSH on loopback port 2222. A client holding a key the file lists connects
under any user name and has the TUI, and through it every agent the daemon
runs: it can ask them, and approve or deny what they are waiting on. Only the
keys in the file are read; options such as `from=` and `command=` are not
applied. Keys are the only way in: there are no passwords, no commands, no
subsystems and no forwarding. `ssh.ip` in `config.yaml` listens beyond
loopback.

### HTTP API

The API listens on loopback port 4747, and every request presents a bearer
token that `tars token create` made. A token grants a set of actions (read,
message, decide, define, serve) on the agents under a key prefix. An agent
outside the prefix is answered as one that does not exist, and an action the
token was not granted is refused with 403. The store holds each token as the
SHA-256 of its secret, never the secret. A node reads a token through
consensus and trusts what it read for 15 seconds. Revoking a token refuses
it, and ends every event stream and worker socket open on it, at once on
every node the revocation reaches. A node it does not reach, such as one cut
off from its quorum, stops trusting the token within 15 seconds: it must
read it through consensus again, cannot, and refuses requests with 503,
while re-reading the tokens its open connections hold every 15 seconds
closes them. `http.ip` in `config.yaml` listens beyond loopback.

### Notifications

A Slack target posts a parked call's name, arguments and question to its
channel. With an `app_token`, anyone in that channel can press Approve or
Deny, and the press decides the call as `tars approve` would, unless
`approvers` lists the Slack user ids that may. Slack delivers presses over a
Socket Mode connection the daemon opens, so no port is opened for them. A
webhook target posts the same notice to its URL, signed with HMAC-SHA256 when
it has a `secret`; nothing comes back through a webhook.

A call waiting on a person to connect an account is posted without its link
or code: whoever completes that link connects their own account in the
user's place. Its Show link button answers the person pressing, and no one
else, with the link and code, under the same rule as Approve. Set
`approvers` wherever not everyone in the channel should connect accounts for
the agents that post there.

### Credentials

OAuth tokens and named credentials are sealed with AES-256-GCM, under the
vault's keys, before they are stored. Model providers' keys are read from the
environment. An MCP server started as a command is given only the
environment variables its `inherit_env` names, beside those its own config
sets, and runs as the daemon's user, so it can read what the daemon can.

### Agents

What an agent can do is what its tools can do. An agent with a policy has
every tool call decided by it: allowed, denied, or parked until a person
approves it. A budget does the same for what the agent spends on its model.
An agent with no policy may make any call its tools allow.

Anything a tool returns reaches the model and can steer it, so a policy
decides what an agent's calls may do, whoever asked for them. A call recorded
as begun and never finished, by an agent lost part way through it, does not
run again until a person approves it.
