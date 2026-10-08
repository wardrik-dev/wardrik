# Security

## Reporting a vulnerability

Report it privately, through this repository's Security tab under "Report a
vulnerability", rather than in a public issue.

## The model

The daemon runs as one user, and whatever can act as that user can do what
Wardrik does: read its store, use its credentials, and run its agents' tools. Run
it on a host, or in a container, that you do not share with accounts you do
not trust.

### Distribution

The node's Erlang distribution listens on loopback, and so does epmd when the
node starts it. The CLI (`wardrik status`, `ask`, `approve` and the rest) and
`wardrik remote` reach the node that way, as do the other nodes of a cluster.

Distribution checks one thing: the cookie, 48 random characters written to
`~/.local/share/wardrik/cookie` on first start, readable by the daemon's user
only. The release hands the cookie to each Erlang VM on its command line, and
`bin/wardrik` to `erl_call` on its, so any account on the host that can list
processes can read it, and anything that holds the cookie and reaches the port
can run any code on the node as the daemon's user. What distribution sends
between nodes is not encrypted.

`WARDRIK_DIST_INTERFACE` moves distribution beyond loopback, for a cluster that
spans hosts. It is refused unless `WARDRIK_DIST_EXPOSED=1` is set beside it, and a
node started that way says so as it starts. Use it only on a private network
that authenticates its members and encrypts their traffic, such as Tailscale
or WireGuard, and never on a public interface.

### Files

| Directory | What it holds | Who can read it |
| --- | --- | --- |
| `~/.config/wardrik` | `config.yaml`, agent and policy files, `ssh/authorized_keys` | as its owner sets it; `${NAME}` in `config.yaml` reads a value from the environment, or the vault where the environment does not set it, so the file need hold no secret |
| `~/.local/share/wardrik` | the store, with every agent's conversation, the ledger, budgets and sealed tokens; the cookie; the SSH host key; `vault_key`, where the vault's key is kept when none is configured | the daemon's user |
| `~/.local/state/wardrik` | logs | the daemon's user |

The release sets umask 077, so what the node and the commands it starts write
is readable by the daemon's user only, and it makes the data and state
directories private again on every start.

Where neither `WARDRIK_VAULT_KEY` nor `vault.keys` in `config.yaml` gives the
vault a key, the first `wardrik vault put` asks to make one, and keeps it in
`~/.local/share/wardrik/vault_key`, readable by the daemon's user only. The
daemon reads it into its own settings, never its environment, so no MCP
command inherits it. The file sits beside the store, so anyone who can read
both can read every secret the vault seals; to keep them apart, set a key of
your own instead. The nodes of a cluster on one machine share the file; a
node on another host needs a copy, as it needs the cookie, or `vault.keys`.

### SSH

Once `~/.config/wardrik/ssh/authorized_keys` exists, the daemon serves the TUI
over SSH on loopback port 2222. A client holding a key the file lists connects
under any user name and has the TUI, and through it every agent the daemon
runs: it can ask them, and approve or deny what they are waiting on. Only the
keys in the file are read; options such as `from=` and `command=` are not
applied. Keys are the only way in: there are no passwords, no commands, no
subsystems and no forwarding. `ssh.ip` in `config.yaml`, or `WARDRIK_SSH_IP`,
listens beyond loopback.

### HTTP API

The API listens on loopback port 4747, and every request presents a bearer
token that `wardrik token create` made. A token grants a set of actions (read,
message, decide, define, serve) on the agents under a key prefix. An agent
outside the prefix is answered as one that does not exist, and an action the
token was not granted is refused with 403. A token that can define agents is
made with a ceiling, a policy of `policies/` given as `--policy`, or with
`--unlimited`: every agent it defines is held to its ceiling ahead of the
definition's own policy, and the strictest of them decides each call, so a
definition cannot allow what its ceiling asks about or denies. An agent keeps
the ceiling it was defined under until it is defined again, and revoking the
token leaves the agents it defined running. The store holds each token as the
SHA-256 of its secret, never the secret. A node reads a token through
consensus and trusts what it read for 15 seconds. Revoking a token refuses
it, and ends every event stream and worker socket open on it, at once on
every node the revocation reaches. A node it does not reach, such as one cut
off from its quorum, stops trusting the token within 15 seconds: it must
read it through consensus again, cannot, and refuses requests with 503,
while re-reading the tokens its open connections hold every 15 seconds
closes them. `http.ip` in `config.yaml`, or `WARDRIK_HTTP_IP`, listens beyond
loopback. The API speaks plain HTTP, so a token sent across a network is
readable on it unless a proxy in front of the daemon ends TLS.

### The Docker image

The image sets `WARDRIK_HTTP_IP` and `WARDRIK_SSH_IP` to `0.0.0.0`, since
inside a container loopback is reachable from nowhere else, and so the ports a
container is run with decide who reaches the API and the TUI:
`-p 127.0.0.1:4747:4747` keeps the API to the host. Distribution and epmd stay
on the container's loopback, so only a process inside the container, such as
`docker exec`, reaches the node. It runs as the user `wardrik`, not root, and
keeps its cookie, store and host key on the `/data` volume, readable by that
user alone.

### Gated tools and outside content

A gated tool's call runs only where a rule of the agent's policy names it; a
policy's `default: allow` does not, so an agent with no policy, or one defined
over HTTP with none, asks a person before every such call. An MCP server's
tool, and a tool worker's, is gated unless the server or worker marks it
read-only, and `gated` on an MCP server in `config.yaml` decides instead.
Wherever a waiting call is shown, it says what its turn had read first.

A turn carries labels for what it has read. One that has read content nobody
on the agent's side wrote, the results of `web_search` or `deep_research`, an
MCP server not marked `trusted`, or a tool worker unless
`http.trusted_workers` is set, carries `outside`, and under a policy every
gated call in it waits on a person, who sees what it would do, unless an
`allow_after` rule for `outside` names it. This is what stops a page or an
issue written to be read by an agent from running a command a rule
pre-approved: an agent may read content from outside, reach what is private,
or change things, and a person decides where it would do all three. Only a
policy the operator writes, in `policies/` or an agent file, may say
`allow_after`. A gated call waits on a person under no policy at all, since
nothing allows it by name.

What a turn read stays in the agent's conversation, so every turn after it
carries its labels too, until `wardrik clear` empties the conversation; a
summary of the conversation keeps them. A subagent begins with its caller's
labels, and the tool call that ran it carries what it read. A file keeps the
labels of the turns that wrote it, an append or an edit keeps those it had,
and reading, listing or finding it labels the reader's turn, so a finding
left in a shared tree carries what its writer read to every agent that reads
it. One an agent file's `context` reads into every turn labels each turn from
its start, and of the files a turn is only told the names of, a name is shown
only where it is plain, letters, digits, `.`, `-` and `_`, since a name is text
a labelled run may have chosen too. The labels are kept with the turn, so a
turn carried on after its node is lost carries them still.

### Notifications

A Slack target posts a parked call's name, arguments and question to its
channel. With an `app_token`, anyone in that channel can press Approve or
Deny, and the press decides the call as `wardrik approve` would, unless
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

OAuth tokens and the secrets `wardrik vault put` keeps are sealed with
AES-256-GCM, under the vault's keys, before they are stored. A server's
credential is found in the vault for each call, the agent's user's before its
org's before the deployment's, so a secret put for an org reaches all of its
agents that hold none of their own. An account connected over OAuth acts as
whoever connected it, so it reaches their calls alone: a user whose org
connected one is asked to connect their own. Where none is held and an OAuth
provider has the same name, the user, or the org, is asked to connect an
account, which the vault keeps as theirs. Model providers' keys, tools' keys
and `${NAME}` in `config.yaml` are read from the environment, and, for a name
it does not set, from the deployment's secret of that name in the vault.
Anyone who can read both the store and the vault's key can read them, as they
can every secret the vault holds. A key from the vault is put in the daemon's
application settings, never its environment. `storage`, `cluster` and `vault`
in `config.yaml` read the environment alone. An MCP server started as a
command is given only `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LOGNAME`, `PATH`,
`SHELL`, `TERM`, `TMPDIR` and `USER` of the daemon's environment, beside those
its own config sets, and runs as the daemon's user, so it can read what the
daemon can.

### Agents

What an agent can do is what its tools can do. An agent with a policy has
every tool call decided by it: allowed, denied, or parked until a person
approves it. A budget does the same for what the agent spends on its model.
An agent with no policy may make any call its tools allow.

Anything a tool returns reaches the model and can steer it, so a policy
decides what an agent's calls may do, whoever asked for them. A call recorded
as begun and never finished, by an agent lost part way through it, does not
run again until a person approves it.
