---
title: The front door
description: "The agent wardrik init writes: ask it for an outcome, approve its plan, and it runs the work."
sidebar:
  order: 0.5
---

`wardrik init` writes one agent, `assistant`: the front door. Tell it an outcome. It proposes the
work as tool calls, and runs them once you approve.

```sh
wardrik ask assistant "Tell me when https://elixir-lang.org/atom.xml has a new post"
```

```text
I'll set up a watcher on that feed. Plan:

• A worker, elixir-blog-watch, checks the feed every 30 minutes. A check costs nothing until a
  new post appears.
• When one lands, it keeps a line about it, and I'll pass it on when you ask.

Waiting on a person for 1 call:
  ? agent_create  call_8d2ebbfe28aa4ee1a269dee2
```

```sh
wardrik approval approve assistant call_8d2ebbfe28aa4ee1a269dee2
wardrik approval deny assistant call_8d2ebbfe28aa4ee1a269dee2 --reason "Once an hour is enough."
```

A denied call comes back to it with your reason, and it proposes again.

## See what runs

The workers it makes are ordinary agents of your org:

```sh
wardrik ls                              # each agent, and what it's doing
wardrik trigger ls elixir-blog-watch    # its triggers, and when each runs
wardrik agent history elixir-blog-watch # what it found
```

Or ask it: "What are you doing for me?" Change or stop work the same way, in plain words. Each
change is a call you approve.

## Its file

```markdown title="~/.config/wardrik/agents/assistant.md"
---
description: "The front door: turns what people ask for into work that runs."
tools: [self/*, agents/*, agent_create, files, web_search, run_lua]
context: [MEMORY.md]
policy: {budget: {tokens: 2000000, per: day}}
idle_timeout: infinity
---
You are Wardrik, the one place the people of this org come to get things done. …
```

- `agents/*` reads, asks and redefines the org's agents. `agent_create` makes a worker.
- Reads run freely. Every change waits on a person.
- `files` gives it a tree of files. `MEMORY.md` is read into every turn.
- No `model`: it runs `config.yaml`'s `defaults`.
- Its workers are held to its policy and budget.
- `web_search` is there once `config.yaml` has a `brave.api_key`.

`init` also writes the role and binding that let it act on the org's agents:

```yaml title="~/.config/wardrik/config.yaml"
roles:
  workers: {rules: [{verbs: [create, define, read, ask], kinds: [agent]}]}
bindings:
  - {org: acme, role: workers, subjects: [agent:assistant]}
```

See [Orgs, roles and tokens](/run/orgs/).

## Change it

- The body is its instructions, then a playbook of work that runs well. Edit it, then
  `wardrik reload`. `init` never overwrites the file.
- To hand tasks to workers without asking, allow the tool: `policy: {allow: [agent_ask], ...}`.
- Add `channels: [slack]` to answer in [Slack](/channels/slack/).
- Once it reads [content from outside](/concepts/outside-content/), every change waits again,
  `allow` or not.
