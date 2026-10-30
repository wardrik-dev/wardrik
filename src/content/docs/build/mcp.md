---
title: Connect MCP servers
description: "Give agents the tools of an MCP server, run as a command or reached over HTTP, and decide which they may call."
sidebar:
  order: 1
---

Name MCP servers in `config.yaml`, then give their tools to an agent. A server runs as a command, or
is reached over HTTP:

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

`${NAME}` reads the environment, else the deployment's secret in the vault. So the file holds no
secret:

```sh
echo "$LINEAR_TOKEN" | wardrik vault put LINEAR_TOKEN   # 1. seal the token
systemctl --user restart wardrik                       # 2. or: wardrik stop && wardrik start
wardrik doctor                                         # 3. checks each server can be reached
```

Every key a server takes is in [`config.yaml` › mcp](/reference/config/#mcp).

## Give an agent the tools

An agent file names a server's tools as `server/*`:

```yaml
tools: [linear/*, notes/*]
```

To narrow what a server offers, use `only` or `except` in `config.yaml`. To decide which calls may
run, use a [policy](/concepts/policy/). A policy names a tool as `linear/search_issues`.

## Which orgs a server serves

A server serves the deployment's [org](/concepts/agents/#keys-and-orgs). To serve other orgs, list
it under each in `orgs`:

```yaml
org: acme

mcp:
  linear:                                  # acme's: no org lists it
    url: https://mcp.linear.app/mcp
  globex-crm:                              # globex's alone
    url: https://crm.globex.example/mcp
  docs:                                    # every org's
    url: https://docs.example.com/mcp

orgs:
  "*":
    mcp: [docs]
  globex:
    mcp: [globex-crm]
```

A name that `mcp` doesn't define is refused. See [`orgs`](/reference/config/#orgs).

A server's `headers` and `env` are the deployment's credentials, shared by every org it serves. To
reach a service as each org or user, use a `credential`; see [Connect accounts](/build/accounts/).

## Which calls need a person

A tool the server doesn't mark read-only is gated: its calls wait on a person unless a policy allows
them by name. A server's answers are content from outside unless it's `trusted`:

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

See [Gated tools](/concepts/rules/#gated-tools) and
[Content from outside](/concepts/outside-content/).

## Add a server while the daemon runs

An org or a person can add an MCP server for their own agents, with no change to `config.yaml`.
From the command line:

```sh
wardrik server add linear --url https://mcp.linear.app/mcp --oauth --user maria
wardrik server ls --user maria
wardrik server rm linear --user maria
```

`server add` prints where to sign in. Its agents sign in with one of:

| Flag | How |
| --- | --- |
| `--oauth`, with a `--scope` for each scope | the owner signs in in a browser |
| `--secret NAME` | a secret the owner holds in the [vault](/build/vault/) |
| neither | nothing |

`--only` takes the server's tool names, with commas. With no `--org` or `--user`, the server is the
deployment's org's.

### From the SDK

Maria works with a token for her own agents:

```sh
wardrik token create maria --resource 'acme/@maria/*' --role reader,messenger,definer
```

Her agent can name a server before she adds it. It offers nothing from it yet, and its definition
says so:

```ts
import { Wardrik } from "@wardrik/sdk";

const wardrik = new Wardrik({ token: process.env.MARIA_TOKEN });
const triage = wardrik.agent("acme/@maria/triage");

await triage.define({
  model: "anthropic:claude-haiku-4-5",
  instructions: "Triage new Linear issues and label each by area.",
  tools: ["linear/*"],
});

console.log((await triage.definition()).missing); // [ 'linear/*' ]
```

She adds Linear's hosted server, and signs in to Linear at the link it answers:

```ts
const added = await wardrik.mcpServers.add({
  owner: "acme/@maria",
  name: "linear",
  url: "https://mcp.linear.app/mcp",
  auth: { oauth: {} },
});

console.log(added.authorization?.url); // where she signs in to Linear
```

Once she has signed in, her agent calls Linear's tools on its next turn. It isn't defined again:

```ts
for await (const event of triage.stream("What came in overnight?")) {
  if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);
}
```

To take the tools away on the next turn, and forget her sign-in:

```ts
await wardrik.mcpServers.remove("linear", { owner: "acme/@maria" });
```

### Whose server an agent gets

For each `server/*` an agent names, the first match wins:

1. The server its owner added.
2. The server its org added, for a user's agent.
3. The server `config.yaml` names, if it serves the agent's org.

`servers/*` gives an agent the tools of every server its owners add, as they add them. A user's
agent gets the org's servers too.

- `wardrik agent show` lists a server the agent names that offers nothing yet as `missing`.
- A server added at runtime is reached over Streamable HTTP. Its answers are content from outside,
  and every tool it doesn't mark read-only waits on a person.
- See [Servers](/reference/http-api/#servers) for the operations.

## Details

### Names

- `*` in an agent file gives every server the agent can reach, with every other tool.
- A file can't name one tool of a server. Narrow it with `only` or `except`, by the server's own
  tool names.
- The model sees each tool as `server__tool`, such as `linear__search_issues`, with the server's own
  description and JSON Schema.
- `prefix` renames the server's tools for the model and policies. An agent file still names the
  server by its own name.
- `wardrik reload` reads the agent files again, never `config.yaml`.

### Commands

- `command` takes `args` and `env`.
- The command inherits the daemon's environment, plus its `env`.
- The service runs with systemd's `PATH`, not your shell's. Name a program under your home
  directory, as `npx` often is, by its full path.
- In Docker, the program must be in the image: build `FROM ghcr.io/wardrik-dev/wardrik`.

```yaml
mcp:
  github:
    command: github-mcp-server
    args: [stdio]
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_TOKEN}
```

### Over HTTP

- `url` is the server's Streamable HTTP endpoint, with `headers` sent on every request.
- A key in `headers` is the deployment's: every agent reaches the server as the deployment.
- To reach it as each org, seal its key for each, `wardrik vault put linear --org acme`, and name it
  as `credential: linear`. It's sent as `authorization: Bearer <token>`.

### Gating and trust

- `gated` lists the gated tools, `true` for all, or `false` for none. A name ending in `*` names
  every tool it begins.
- Without `trusted: true`, a turn that read a server's answer, and every turn after it, waits on a
  person before a gated call runs.

### Limits

- `timeout` is seconds a call may take, 60 unless set.
- `max_result_bytes` is how much of a result the model gets, 128 KB unless set. A longer one is cut,
  and the model is told.
- Structured content is given where the server returns some, text otherwise. An image isn't read;
  the model is told there was one.

### When a server is down

- A server that's down offers no tools. Its agents carry on without them.
- The daemon reconnects by itself, waiting longer each time, up to a minute.
- A server that says its tools changed is asked for them again.
- A failed call that reads or can be repeated is retried.
