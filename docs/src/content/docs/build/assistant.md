---
title: The assistant
description: "Use the built-in assistant to create and manage agents, answer questions about Wardrik, and check how things run, with approval for changes."
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

## Ask it questions

Ask how Wardrik works or where something is. It answers from this documentation and from the
deployment itself, and links the page it used:

```sh
wardrik ask assistant "Where is the config file?"
wardrik ask assistant "What are triggers?"
wardrik ask assistant "Why did changelog-watch stop?"
```

- `wardrik_about` gives this deployment's version, URLs, and where its config, agent files, env
  file, keys, store and logs are.
- `docs_search` and `docs_read` read these pages.
- `wardrik_doctor` runs the checks `wardrik doctor` runs.
- To find out why an agent failed, it reads the agent's runs, its timeline, what it gets from its
  owner, and the calls waiting on a person.

## Set things up

Ask it to add an MCP server, a notify target or an OAuth app. Each addition requires your approval.
It never sees or sets a secret's value: it answers the dashboard page and the command where you
seal one:

```text
Seal GITHUB_TOKEN at http://127.0.0.1:4747/web/secrets?owner=acme, or run:
wardrik vault put GITHUB_TOKEN --for header --org acme
```

A secret is read only for its purpose: `header` for an MCP server's token, `api_key` for a model's
or tool's key, `client_secret` for an OAuth app, `signing_secret` for signing notices. It asks
for a secret before it adds what uses it.

Removing a server, target or app is yours to do, in the [dashboard](/run/dashboard/) or with the
CLI.

## The check

Every 6 hours, its `check` trigger looks at its workers' runs, the calls waiting on a person, the
doctor's checks and each node's memory. It answers "All well." when nothing needs you. When
something does, it proposes the fix as a call that waits for your approval, so it shows in
`wardrik approval ls`, the dashboard's Approvals page and any [notify target](/build/notices/).
Each check is a model call with the assistant's tools, often tens of thousands of tokens. Remove
the trigger to stop it, or change `every`.

## Assistant configuration

```markdown title="~/.config/wardrik/agents/assistant.md"
---
description: "Turns what people ask for into work that runs."
tools: [self/*, agents/*, agent_create, ops/agent.runs, ops/agent.timeline, ops/agent.resolved,
  ops/interrupts.list, ops/deployment.runtime, settings, help, files, web_search, run_lua]
context: [MEMORY.md]
policy: {budget: {tokens: 2000000, per: day}}
idle_timeout: infinity
triggers:
  - name: check
    every: 6h
    prompt: >-
      Check how things run: ...
---
You are Wardrik, the one place the people of this org come to get things done. …
```

- `agents/*` reads, messages and redefines the org's agents. `agent_create` creates another agent.
- `ops/agent.runs` and the other `ops/` entries read runs, timelines, what an agent gets, waiting
  calls and each node's resource use. Each tool goes into every model call, so it names only these
  reads, not all of `ops/read`.
- `settings` lists and adds MCP servers, notify targets and OAuth apps, and asks you to seal
  secrets. `help` answers from these docs and the deployment's own files.
- Reads run without approval. Every change needs approval.
- `files` gives it a workspace. `MEMORY.md` is loaded into every turn.
- No `model`: it uses `defaults` from `config.yaml`.
- Agents it creates inherit its policy and budget.
- `web_search` works once it has a Brave key: `wardrik vault put BRAVE_API_KEY --for api_key`.
  Until then, it says how to add one.

`init` also writes the roles and bindings that let it act on the org's agents and settings,
read the deployment, and list the deployment's secrets by name:

```yaml title="~/.config/wardrik/config.yaml"
roles:
  workers:
    rules:
      - {verbs: [create, define, read, ask, events], kinds: [agent]}
      - {verbs: [read, add], kinds: [mcp_server, notify_target, provider]}
      - {verbs: [read], kinds: [secret]}
  observer:
    rules:
      - {verbs: [nodes, runtime, audit], kinds: [deployment]}
      - {verbs: [read], kinds: [secret]}
bindings:
  - {org: acme, role: workers, subjects: [agent:assistant]}
  - {org: deployment, role: observer, subjects: [agent:assistant]}
```

See [Organizations, roles, and tokens](/run/orgs/).

## Customize the assistant

- The body is its instructions, followed by a playbook of patterns that work. Edit it, then
  `wardrik reload`. `init` never overwrites the file. `wardrik doctor` names the tools an older
  file leaves out.
- To message other agents without approval, allow the tool: `policy: {allow: [agent_ask], ...}`.
- Add `channels: [slack]` to use it from [Slack](/build/slack/).
- After it reads [untrusted content](/concepts/outside-content/), every change needs approval,
  even if allowed.
