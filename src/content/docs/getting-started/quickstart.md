---
title: Quickstart
description: "Install Wardrik, ask the front door for an outcome, write an agent, and approve a call its policy holds."
---

Install Wardrik, hand the front door some work, then write an agent of your own.

## 1. Install

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik_daemon/releases/download/v0.1.0-rc.2/install.sh | sh
wardrik init
```

`init` asks for your model provider and key, writes `~/.config/wardrik/`, and starts the daemon.
See [Install](/getting-started/install/) for Docker and flags.

## 2. Ask the front door

```sh
wardrik ask assistant "Tell me when https://elixir-lang.org/atom.xml has a new post"
```

It explains its plan, then waits for you before it makes an agent:

```text
Waiting on a person for 1 call:
  ? agent_create  call_8d2e  agent_create needs your approval.
Decide with: wardrik approval approve assistant ID, or wardrik approval deny assistant ID
```

```sh
wardrik approval approve assistant call_8d2e
wardrik ls
```

`wardrik ls` shows the new agent. See [The front door](/build/front-door/).

## 3. Write an agent

An agent is a Markdown file. The frontmatter is its definition. The body is its instructions.

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

The model calls `write_file`, and the policy holds it:

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

- An approval runs the call as the model wrote it.
- A denial tells the model your reason, and the turn goes on.

## Next

- [Tools in your app](/build/tool-workers/): offer agents tools from your own code.
- [Slack](/channels/slack/): answer in a channel, with Approve and Deny in the thread.
- [Policy](/concepts/policy/): what else a policy can say.
- [Agent files](/reference/agent-files/): every key an agent file takes.
- [Examples](/examples/): agents to copy and run.
