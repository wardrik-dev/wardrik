---
title: The assistant
description: "The agent wardrik init creates. Ask it for an outcome, approve its tool calls, and it creates the agents that do the work."
sidebar:
  order: 0.5
---

`wardrik init` creates an agent named `assistant`. Send it a request. It replies with a plan and
the tool calls to carry it out. Each call runs after you approve it.

```sh
wardrik ask assistant "Tell me when https://github.blog/changelog/feed/ has a new post"
```

```text
I'll set up a watcher on that feed. Plan:

• A worker, changelog-watch, checks the feed every 30 minutes. A check costs nothing until a
  new post appears.
• When one lands, it keeps a line about it, and I'll pass it on when you ask.

Waiting on a person for 1 call:
  ? agent_create  call_8d2ebbfe28aa4ee1a269dee2
```

```sh
wardrik approval approve assistant call_8d2ebbfe28aa4ee1a269dee2
wardrik approval deny assistant call_8d2ebbfe28aa4ee1a269dee2 --reason "Once an hour is enough."
```

On a denial, it receives your reason and proposes again.

## See what runs

The workers it creates are ordinary agents in your org:

```sh
wardrik ls                              # each agent, and what it's doing
wardrik trigger ls changelog-watch    # its triggers, and when each runs
wardrik agent history changelog-watch # what it found
```

Or ask it: "What are you doing for me?" Ask it to change or stop work the same way. Each change
is a tool call you approve.

## Its file

```markdown title="~/.config/wardrik/agents/assistant.md"
---
description: "Turns what people ask for into work that runs."
tools: [self/*, agents/*, agent_create, files, web_search, run_lua]
context: [MEMORY.md]
policy: {budget: {tokens: 2000000, per: day}}
idle_timeout: infinity
---
You are Wardrik, the one place the people of this org come to get things done. …
```

- `agents/*` reads, messages and redefines the org's agents. `agent_create` creates a worker.
- Reads run without approval. Every change needs approval.
- `files` gives it a workspace. `MEMORY.md` is loaded into every turn.
- No `model`: it uses `defaults` from `config.yaml`.
- Its workers inherit its policy and budget.
- `web_search` works once `config.yaml` sets `brave.api_key`.

`init` also writes the role and binding that allow it to act on the org's agents:

```yaml title="~/.config/wardrik/config.yaml"
roles:
  workers: {rules: [{verbs: [create, define, read, ask], kinds: [agent]}]}
bindings:
  - {org: acme, role: workers, subjects: [agent:assistant]}
```

See [Orgs, roles and tokens](/run/orgs/).

## Change it

- The body is its instructions, followed by a playbook of patterns that work. Edit it, then
  `wardrik reload`. `init` never overwrites the file.
- To message workers without approval, allow the tool: `policy: {allow: [agent_ask], ...}`.
- Add `channels: [slack]` to use it from [Slack](/build/slack/).
- After it reads [content from outside](/concepts/outside-content/), every change needs approval,
  even if allowed.
