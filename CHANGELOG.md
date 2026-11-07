# Changelog

## Unreleased

- README: run a coding agent without asking, by policy or by its own mode.

## 0.1.0-rc.1 (2026-11-06)

- `WardrikACP`, which runs coding agents over ACP, and gives an agent each one as a WardrikCore
  capability.
- `WardrikACP.Harness`, a coding agent as data: command, environment, session `_meta`, config
  options, instructions and context files.
- Each piece of work has its own git worktree, branch and session.
- Each permission request runs through the agent's middleware as a tool call named by its ACP
  kind. It can be allowed, refused or parked.
- A parked request is answered when the call resumes, after the coding agent stopped too.
- Session cost in USD, measured per call.
- Each request has an ID of its own, `<call ID>:<toolCallId>`. The answer to the call goes to it.
- `WardrikACP.Checkout`: a checkout's `base`, where new branches start, and `fetch`.
- `WardrikACP.sweep/1` removes worktrees whose work is in the base, stopping their idle coding
  agents. It runs at start and every `sweep` milliseconds.
- Guide: Get started, Claude Code end to end in IEx.
