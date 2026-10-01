---
title: Quickstart
description: Write an agent file, ask the agent something, and reach it over the HTTP API.
---

This takes a daemon you have [installed](/getting-started/install/) and running, and gives it its
first agent.

## Give it a model

An agent's model is named as `provider:model`, and the daemon reads the provider's key from its
environment. Put it in `~/.config/wardrik/env`, which the service reads:

```sh
echo "ANTHROPIC_API_KEY=sk-ant-..." >> ~/.config/wardrik/env
systemctl --user restart wardrik
```

With `wardrik start` instead of the service, export it in the shell you start it from.

## Write an agent

An agent is a Markdown file in `~/.config/wardrik/agents`. Its frontmatter says what it is and what
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

A file with no `org` or `user` is the agent `_/_/triage`, after its name.

## Ask it something

```sh
wardrik ask _/_/triage "Start a MEMORY.md with today's date and what you are for."
```

`wardrik ask` follows the answer as it arrives. Ask again and the agent reads the `MEMORY.md` it
wrote. `wardrik history _/_/triage` shows what it has said, and `wardrik watch _/_/triage` follows
everything it does.

## Reach it over HTTP

```sh
wardrik token create dev --all --unlimited
curl -s -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents
```

The token is printed once. The [HTTP API](/reference/http-api/) lists, defines and asks agents, and
streams what they do as [events](/reference/events/).

## Next

- [Agents](/concepts/agents/): how an agent answers in turns, and where it runs.
- [Policy and approvals](/concepts/policy/): what an agent's tool calls may do, and which wait on a
  person.
- [Connect MCP servers](/guides/mcp/): give agents the tools of the services you use.
- [Run an agent on a schedule](/guides/schedules/): ask it something on a clock.
- [Agent files](/reference/agent-files/): every key an agent file takes.
