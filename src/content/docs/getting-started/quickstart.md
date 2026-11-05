---
title: Quickstart
description: "Install Wardrik, send the assistant a request, write an agent, and approve a tool call."
---

Install Wardrik, send the assistant a request, then write your own agent.

## 1. Install

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik_daemon/releases/download/v0.1.0-rc.7/install.sh | sh
wardrik init
```

`init` prompts for a model provider and key, writes `~/.config/wardrik/`, and starts the daemon.
See [Install](/getting-started/install/) for Docker and flags.

## 2. Ask the assistant

```sh
wardrik ask assistant "Tell me when https://github.blog/changelog/feed/ has a new post"
```

It replies with a plan and an `agent_create` call that needs approval:

```text
? waits on you after 6s

╭─ agent_create ─────────────────────────╮
│ { "name": "changelog-watch", … }       │
╰────────────────────────────────────────╯
Approve agent_create? [y/n, Enter leaves it]
```

Type `y`. Off a terminal, or after Enter, approve it later:

```sh
wardrik approval approve assistant call_8d2e
wardrik ls
```

`wardrik ls` lists the new agent. See [The assistant](/build/assistant/).

## 3. Write an agent

An agent is a Markdown file. The frontmatter is its definition, and the body is its instructions.

```markdown title="~/.config/wardrik/agents/notes.md"
---
description: Keeps the team's notes.
tools: [files]
policy:
  ask:
    write_file: This writes a note.
---
You keep the team's notes in files. Say what you would write before you write it.
```

```sh
wardrik reload
wardrik ask notes "Start a MEMORY.md with today's date and what you are for."
```

- The file name, `notes`, is the agent's name.
- It has no `model`, so it uses `defaults.model` from `config.yaml`.

## 4. Approve a call

The model calls `write_file`, which the policy requires approval for:

```sh
wardrik approval ls
```

```text
AGENT  CONVERSATION  CALL       TOOL        WHY
notes                call_5b1f  write_file  This writes a note.
```

```sh
wardrik approval approve notes call_5b1f
# or
wardrik approval deny notes call_5b1f --reason "Keep it to one line."
```

On a denial, the model receives your reason and the turn continues. See [Approvals](/concepts/approvals/).

## Next

- [Tools in your app](/build/tool-workers/): serve tools to agents from your own code.
- [Slack](/build/slack/): use agents in Slack, with Approve and Deny buttons in the thread.
- [Policy](/concepts/policy/): every policy rule.
- [Agent files](/reference/agent-files/): every key an agent file takes.
- [Examples](/examples/): agents to copy and run.
