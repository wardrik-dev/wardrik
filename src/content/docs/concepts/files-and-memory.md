---
title: Files and memory
description: "Store agent files, load persistent context into each turn, and share files between agents."
sidebar:
  order: 7
---

Add `files` to give an agent a persistent workspace. List files under `context` to load them at
the start of every turn, so the agent can use saved notes across conversations.

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
- Overwriting a file requires the version from `read_file`. A stale version is rejected.
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

Wardrik rejects mounts that are not allowed by `config.yaml`.

## Writing files from outside

People and apps write an agent's files with the CLI or the [HTTP API](/reference/http-api/#files):

```sh
wardrik agent files put triage MEMORY.md ./memory.md
wardrik agent files sync runbooks ./runbooks --delete
```

- `sync` writes the files of a directory whose content differs, so a directory kept in git can be
  the source of an agent's files.
- Files written this way have no labels. The agent treats them as it treats its definition.
- Agents can't use these operations. They reach other agents' files through mounts.

See [`agent files`](/reference/cli/#files) and [Skills](/build/skills/).

## Content from outside

A file written by a turn that read [untrusted content](/concepts/outside-content/) is labeled
`outside`. Reading that file applies the same label to the turn.
