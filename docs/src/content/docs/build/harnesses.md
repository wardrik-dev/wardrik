---
title: Connect coding agents
description: "Run Claude Code and other ACP coding agents as tools. Each change they make needs approval, and each piece of work gets its own branch."
sidebar:
  order: 1.5
---

Connect a coding agent that speaks the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP), such as Claude Code. An agent sends it a task. The coding agent works in a git worktree,
asks before each change, and commits on a branch of its own.

This page runs Claude Code end to end. Requires Node.js, git, and Claude Code signed in or an
Anthropic API key.

## 1. Install the ACP adapter

```sh
npm install -g @agentclientprotocol/claude-agent-acp
claude-agent-acp --version
```

## 2. Make a repository

```sh
mkdir -p ~/acp-demo && cd ~/acp-demo
git init -b main
printf 'defmodule Demo do\n  def hello, do: "Hello"\nend\n' > demo.ex
printf '# Demo\n\nOne module, demo.ex. Keep changes small.\n' > AGENTS.md
git add . && git commit -m "First"
```

## 3. Configure the harness

```yaml title="~/.config/wardrik/config.yaml"
harnesses:
  claude:
    command: claude-agent-acp
    env: {ANTHROPIC_API_KEY: "${ANTHROPIC_API_KEY}"}
    meta: {claudeCode: {options: {settingSources: []}}}
    options: {mode: default}
    context: [CLAUDE.md, AGENTS.md]
checkouts:
  demo: ~/acp-demo
```

```sh
systemctl --user restart wardrik
wardrik doctor            # checks the command and each checkout
```

- `settingSources: []` stops Claude Code from loading `~/.claude/settings.json` and the
  repository's `.claude/`, so neither one can allow a tool.
- `mode: default` makes Claude Code ask before each change. Its own default, `auto`, may not ask.
- Without `env`, Claude Code uses its own sign-in from `~/.claude`.
- See all settings in [`config.yaml` › harnesses](/reference/config/#harnesses).

## 4. Define an agent

```markdown title="~/.config/wardrik/agents/builder.md"
---
description: Sends coding work to Claude Code.
tools: [claude]
policy: coding
---
You send coding work to the claude tool, then say what it did.
```

```yaml title="~/.config/wardrik/policies/coding.yaml"
allow: ["claude/execute(command = mix test)"]
deny: [claude/delete]
default: {read_only: allow, else: ask}
```

- Each harness is a tool of the same name.
- Each request from Claude Code is a call named by its ACP kind: `claude/read`, `claude/edit`,
  `claude/execute`, `claude/delete`, `claude/fetch`, and so on.
- A rule matches a request's input, such as `command`, and its paths relative to the repository:
  `claude/edit(lib/*)`.

## 5. Ask for a change

```sh
wardrik reload
wardrik ask builder "Use claude on the demo checkout, work add-greet: add greet/1 to demo.ex, returning \"Hello, NAME!\", then commit it."
```

```text
→ claude {"checkout":"demo","task":"Add greet/1 ...","work":"add-greet"}

╭─ claude__edit ─────────────────────────────────────────╮
│ {                                                      │
│   "file_path": ".../demo.ex",                          │
│   "new_string": "...def greet(name), do: ...",         │
│   ...                                                  │
╰────────────────────────────────────────────────────────╯
Approve claude__edit? [y/n, Enter leaves it]
```

Type `y` to approve each request. Type `n` to refuse one, with a reason Claude Code receives.

- `wardrik approval` goes through the requests that wait, showing each one's arguments.
- In Slack, a [notice](/build/notices/) shows each request with **Approve** and **Deny**.

## 6. See the result

```sh
wardrik agent show builder          # its ID, agt_...
cd ~/acp-demo
git log --oneline main..wardrik/AGENT_ID/_/add-greet
```

- The branch is `wardrik/<agent ID>/<conversation>/<work>`, from the checkout's `base`. `main` is
  unchanged.
- The worktree is in `~/.local/share/wardrik/worktrees/claude/demo/`.
- Asking again with the same `work` name continues the same session and branch.

## 7. Merge it

```sh
git merge --squash wardrik/AGENT_ID/_/add-greet && git commit -m "Add greet/1"
```

A sweep runs each day. It removes each worktree whose work is in its checkout's `base`, and the
branch with it. Merged, squashed and cherry-picked work all count. Work with changes or untracked
files stays.

## Run without asking

A coding agent can work with no person in the loop, in one of two ways.

**Wardrik decides each request.** Claude Code still asks, and the policy answers:

```yaml title="~/.config/wardrik/policies/autonomous.yaml"
allow: [claude/*]
deny: [claude/delete, "claude/execute(command = git push*)"]
```

```markdown title="~/.config/wardrik/agents/builder.md"
---
tools: [claude]
policy: autonomous
---
```

- No request asks a person. Deny rules still refuse, and every decision is in the agent's events.
- After Claude Code fetches a web page, gated requests ask again. List under `allow_after.outside`
  the ones that may still run. See [Outside content](/concepts/outside-content/).
- The work stays on its branch until you merge it.

**The coding agent decides each request.** Set its own mode:

```yaml title="~/.config/wardrik/config.yaml"
harnesses:
  claude-open:
    command: claude-agent-acp
    meta: {claudeCode: {options: {settingSources: []}}}
    options: {mode: bypassPermissions}
```

- Claude Code sends no requests, so no policy sees its commands. The worktree, the branch, the
  timeout and the cost are its only limits.
- `acceptEdits` allows edits and still asks before commands.
- Claude Code refuses `bypassPermissions` as root outside a sandbox.

## Start work from a remote branch

```yaml
checkouts:
  core: {path: ~/src/core, base: origin/main, fetch: true}
```

- `base` is where each new branch starts, whatever branch the checkout is on.
- `fetch: true` runs `git fetch` before each new branch and before each sweep.

## Which orgs can use a harness

A harness is available to the deployment's org. List it under `orgs` for other orgs:

```yaml
orgs:
  globex:
    harnesses: [claude]
```

A harness runs on the daemon's machine, with its checkouts. Give it only to orgs you trust with
that machine.
