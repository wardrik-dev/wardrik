---
title: The assistant
description: "Use the built-in assistant to create and manage agents, with approval for changes."
sidebar:
  order: 0.5
---

`wardrik init` creates an agent named `assistant`. Describe a task, then review the tool calls
it proposes to create or configure agents. Changes require your approval.

```sh
wardrik ask assistant "Tell me when https://github.blog/changelog/feed/ has a new post"
```

```text
I'll set up a watcher on that feed. Plan:

• Create an agent named changelog-watch to check the feed every 30 minutes.
• Save a summary of new posts. Checks with no new entries make no model call.
• Retrieve the saved summaries when you ask.

Waiting on a person for 1 call:
  ? agent_create  call_8d2ebbfe28aa4ee1a269dee2
```

```sh
wardrik approval approve assistant call_8d2ebbfe28aa4ee1a269dee2
wardrik approval deny assistant call_8d2ebbfe28aa4ee1a269dee2 --reason "Once an hour is enough."
```

On a denial, it receives your reason and proposes again.

## Inspect created agents

Created agents appear alongside your other agents:

```sh
wardrik ls                              # each agent, and what it's doing
wardrik trigger ls changelog-watch    # its triggers, and when each runs
wardrik agent history changelog-watch # what it found
```

Ask the assistant to list, change, or stop its tasks. Changes require approval.

## Assistant configuration

```markdown title="~/.config/wardrik/agents/assistant.md"
---
description: "Creates and manages agents for requested tasks."
tools: [self/*, agents/*, agent_create, files, web_search, run_lua]
context: [MEMORY.md]
policy: {budget: {tokens: 2000000, per: day}}
idle_timeout: infinity
---
You are Wardrik, the one place the people of this org come to get things done. …
```

- `agents/*` reads, messages and redefines the org's agents. `agent_create` creates another agent.
- Reads run without approval. Every change needs approval.
- `files` gives it a workspace. `MEMORY.md` is loaded into every turn.
- No `model`: it uses `defaults` from `config.yaml`.
- Agents it creates inherit its policy and budget.
- `web_search` works once `config.yaml` sets `brave.api_key`.

`init` also writes the role and binding that allow it to act on the org's agents:

```yaml title="~/.config/wardrik/config.yaml"
roles:
  workers: {rules: [{verbs: [create, define, read, ask], kinds: [agent]}]}
bindings:
  - {org: acme, role: workers, subjects: [agent:assistant]}
```

See [Organizations, roles, and tokens](/run/orgs/).

## Customize the assistant

- The body is its instructions, followed by a playbook of patterns that work. Edit it, then
  `wardrik reload`. `init` never overwrites the file.
- To message other agents without approval, allow the tool: `policy: {allow: [agent_ask], ...}`.
- Add `channels: [slack]` to use it from [Slack](/build/slack/).
- After it reads [untrusted content](/concepts/outside-content/), every change needs approval,
  even if allowed.
