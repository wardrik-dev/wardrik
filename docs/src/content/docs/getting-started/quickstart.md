---
title: Quickstart
description: Set up Wardrik with wardrik init, tell its front door what you want, write an agent of your own, and reach them over the HTTP API.
---

## Set it up

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | sh
wardrik init
```

`wardrik init` asks for a model provider and its key, writes the front door,
`~/.config/wardrik/agents/assistant.md`, starts the daemon, seals the key in the vault, and asks the
front door what it can do for you. [Install](/getting-started/install/) covers Docker, and the flags
that answer `init` in a script.

An agent's model is named as `provider:model`, and the daemon reads the provider's key from the
vault. `wardrik vault put ANTHROPIC_API_KEY` seals another, which every node uses at once. A key set
in the daemon's environment, such as in `~/.config/wardrik/env`, is read before the vault's.

## Tell it what you want

The front door is the one place to ask for what you want. Tell it an outcome:

```sh
wardrik ask assistant "Tell me when https://elixir-lang.org/atom.xml has a new post"
```

It says its plan, what it will watch, how often and what it may spend, and proposes the work as a
call that waits on you. Approve it, and the work runs on its own:

```sh
wardrik parked
wardrik approve assistant CALL
wardrik ls
```

`wardrik ls` lists the worker it defined beside it, and `wardrik triggers` when that worker runs
next. Ask it "What are you doing for me?", or tell it "check every hour" or "stop", and it proposes
the change. See [The front door](/guides/front-door/).

## Write an agent

The front door writes the agents it needs. To write one yourself, an agent is a Markdown file in `~/.config/wardrik/agents`. Its frontmatter says what it is and what
it may call, and its body is its system prompt:

```markdown title="~/.config/wardrik/agents/triage.md"
---
description: Keeps notes on the incident queue.
model: anthropic:claude-sonnet-5
tools: [files]
context: [MEMORY.md]
---
You help the on-call engineer. Keep what you learn in MEMORY.md, and say what
you do not know.
```

`files` gives it a tree of files of its own, and `context` reads `MEMORY.md` into every turn. Read
the agent files again, and the agent starts:

```sh
wardrik reload
wardrik ls
```

The agent is `default/triage`: a file that names no `org` is in the deployment's, which is
`default` unless `config.yaml` names another, and the CLI finds an agent in it by its name alone.

## Ask it something

```sh
wardrik ask triage "Start a MEMORY.md with today's date and what you are for."
```

`wardrik ask` follows the answer as it arrives. Ask again and the agent reads the `MEMORY.md` it
wrote. `wardrik history triage` shows what it has said, and `wardrik watch triage` follows
everything it does.

## Reach it over HTTP

```sh
wardrik token create dev --all --unlimited
curl -s -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents
```

The token is printed once. The [HTTP API](/reference/http-api/) lists, defines and asks agents, and
streams what they do as [events](/reference/events/).

## Next

- [The front door](/guides/front-door/): what it may do, where its results go, and the playbook it
  follows.
- [Recipes](/recipes/): agents to copy and run, from a morning brief to one that anyone may try to
  hijack.
- [Agents](/concepts/agents/): how an agent answers in turns, and where it runs.
- [Policy and approvals](/concepts/policy/): what an agent's tool calls may do, and which wait on a
  person.
- [Connect MCP servers](/guides/mcp/): give agents the tools of the services you use.
- [Trigger an agent](/guides/triggers/): ask it something on a clock.
- [Agent files](/reference/agent-files/): every key an agent file takes.
