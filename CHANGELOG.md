# Changelog

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
