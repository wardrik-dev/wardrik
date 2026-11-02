---
title: Files and memory
description: "An agent keeps files in the store, mounts other agents' workspaces, and reads chosen files into every turn."
sidebar:
  order: 7
---

An agent with `files` in its tools has a workspace of files, kept in the store. Files in
`context` are read into every turn. That's its memory.

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

- Paths are relative, as `notes/2026-10-01.md`. Folders need no creating.
- Replacing a file takes the version it was read at. A stale write is refused.
- A file is text, at most 4 MiB.
- An agent's conversations share its workspace.

## Context

```yaml
context:
  files: [MEMORY.md, shared/runbooks/deploy.md]
  max_bytes: 65536
```

- Up to 20 files, read as each turn begins, 16 KB in all unless `max_bytes` says otherwise.
- A file too long is cut, and the agent is asked to rewrite it shorter.
- The agent also sees the names of other files at the top of its workspace.

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

`config.yaml` says who may mount each workspace, as `agent:NAME` in the same org:

```yaml title="~/.config/wardrik/config.yaml"
workspace:
  shared:
    agent:runbooks: {read: [agent:oncall, agent:triage], write: [agent:ops]}
```

A mount `config.yaml` doesn't allow is refused. In Elixir, your resolver returns the allowed
workspaces by agent ID, as `%Wardrik.Resolved{workspaces: %{"agt_runbooks" => :read}}`.

## Content from outside

A file written by a turn that read [content from outside](/concepts/outside-content/) keeps the
`outside` label. A turn that reads it gets the label too.
