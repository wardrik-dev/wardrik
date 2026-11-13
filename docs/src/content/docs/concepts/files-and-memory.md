---
title: Files and memory
description: "Store agent files, load persistent context into each turn, keep digests of conversations, and share files between agents."
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
| `search_memory` | finds the files that best answer a question in plain words, best first |
| `delete_file` | deletes a file |

- Paths are relative, such as `notes/2026-10-01.md`. Directories are created as needed.
- Overwriting a file requires the version from `read_file`. A stale version is rejected.
- Files are text, up to 4 MiB.
- An agent's conversations share its workspace, digests included. What one conversation writes,
  another can read. Give each audience, such as a private and a public channel, its own agent.

## Context

```yaml
context:
  files: [MEMORY.md, shared/runbooks/deploy.md]
  max_bytes: 65536
```

- Files are loaded at the start of each turn. Limits are in [`context`](/reference/agent-files/#context).
- A file over the limit is truncated, and the agent is asked to shorten it.
- The agent also receives the names of the other top-level files in its workspace.

## Digests

Before an agent sleeps, it writes a digest of each conversation to its workspace. A later
conversation finds it with `search_memory` or `search_files`.

```md title="digests/C0123ABC.md"
---
conversation: C0123ABC
updated: 2026-11-11T16:04:12Z
through: msg_Xq3fA81kP2
---

Maria asked for the open incidents. Two were open; INC-41 was closed after the deploy...
```

To use them, say so in the agent's instructions:

```md
Before you answer someone new to this conversation, run search_memory for their name and what
they ask about.
```

- The file is `digests/<conversation>.md`, or `digests/agent.md` for the agent's own
  conversation. Each digest replaces the last.
- The digest covers the messages up to `through`. The next one reads the digest so far and the
  messages since. Without a new message, none is written.
- The agent's model writes it. Each digest is a model call, and counts towards the agent's
  budget.
- A digest of a conversation that read [untrusted content](/concepts/outside-content/) is labeled
  `outside`.
- It needs the `files` tool. Set [`digest: false`](/reference/agent-files/#digest) to turn it off.
  With `idle_timeout: infinity`, the agent never sleeps, so it writes none.

## Search memory

`search_memory` ranks the agent's files by how well they answer a question, and quotes each
one's best passage:

```json
{"query": "pumpkin squash autumn loaf launch", "glob": "digests/**", "limit": 5}
```

```json
{"ok": true, "hits": [{"path": "digests/C0123ABC.md", "line": 12, "at": "2026-11-11T16:04:12Z",
  "excerpt": "Posted the pumpkin loaf launch to X at 9:00...", "score": 3.41}]}
```

- Any word of the query counts. Files with more of its words, or rarer ones, rank first
  ([BM25](https://en.wikipedia.org/wiki/Okapi_BM25)). A newer file ranks a little higher.
- Words match whole, singular or plural. Other forms of a word, and synonyms, don't match, so
  name the words a file might use.
- It searches the agent's workspace and the trees shared with it, and carries the labels of the
  files it quotes.
- `search_files` finds exact text, with a regular expression.

People and apps search an agent's memory with
[`GET /v1/agents/{agent}/memory`](/reference/http-api/#search-memory) or
`wardrik agent files search`.

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
