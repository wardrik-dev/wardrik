---
title: Files and memory
description: "The files tools manage a per-agent workspace in the store, mount other agents' workspaces, and load chosen files into every turn."
sidebar:
  order: 7
---

An agent configured with the `files` tools is assigned a workspace in the store. Files listed in
`context` are loaded into every turn, which makes them its memory.

```yaml
tools: [files]
context: [MEMORY.md]
```

| Tool | Does |
| --- | --- |
| `read_file` | reads a file, with its version |
| `write_file` | writes a file, or appends with `append` |
| `edit_file` | replaces text that appears once, or everywhere with `all` |
| `list_files` | lists the files a glob matches, newest first |
| `search_files` | finds the lines a regular expression matches |
| `delete_file` | deletes a file |

- Paths are relative, such as `notes/2026-10-01.md`. Directories are created as needed.
- Overwriting a file requires the version from `read_file`. A stale version is refused.
- Files are text, up to 4 MiB.
- An agent's conversations share its workspace.

## Context

```yaml
context:
  files: [MEMORY.md, shared/runbooks/deploy.md]
  max_bytes: 65536
```

- Files are loaded at the start of each turn. Limits are in [`context`](/reference/agent-files/#context).
- A file over the limit is truncated, and the agent is asked to shorten it.
- The agent also receives the names of the other top-level files in its workspace.

## Sharing workspaces

An agent mounts another agent's workspace under `shared/<mount>/`:

```yaml
# in agents/oncall.md
tools: [files]
workspace:
  shared:
    runbooks: agent:runbooks                   # read and write, if allowed
    notes: {agent: agent:notes, mode: read}
```

`config.yaml` defines who can mount each workspace, as `agent:NAME` in the same org:

```yaml title="~/.config/wardrik/config.yaml"
workspace:
  shared:
    agent:runbooks: {read: [agent:oncall, agent:triage], write: [agent:ops]}
```

A mount that `config.yaml` doesn't allow is refused.

## Content from outside

A file written by a turn that read [content from outside](/concepts/outside-content/) gets the
`outside` label. A turn that reads the file gets the label too.
