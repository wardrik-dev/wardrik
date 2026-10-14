---
title: Files and memory
description: The tree of files an agent keeps in the store, the trees it shares, and the files read into every turn.
sidebar:
  order: 5
---

An agent with `files` in its tools has a tree of files of its own. The tree is kept in the store
with the agent, so its notes are on whichever node holds it and survive the node it was on.

```yaml
tools: [files]
```

`files` gives the agent six tools. `*` gives them too, with everything else.

| Tool | What it does |
| --- | --- |
| `read_file` | Reads a file, with its version, numbered by line. At most 2,000 lines or 128 KB a call; `offset` and `limit` read the rest |
| `write_file` | Writes a file, or appends to one with `append` |
| `edit_file` | Replaces text that appears once in a file, or everywhere with `all` |
| `list_files` | Lists the files a glob matches, newest first, with each one's size, when it was written and by whom. At most 500 |
| `search_files` | Finds the lines a regular expression matches, with up to 5 lines around each. At most 200 |
| `delete_file` | Deletes a file |

A file is text, and at most 4 MiB. A path is relative to the top of the tree, such as
`notes/2026-10-01.md`: one that begins with `/` or `~`, or holds `..`, is refused. Folders are only
the beginnings of paths, so there is nothing to create first. In a glob, `*` matches within one
folder, `**` across folders and `?` one character.

A tool that cannot do what it was asked answers the model with what went wrong, as
`{"ok": false, "error": {"code": ..., "message": ...}}`, and the turn carries on.

## Writing over what was read

Every file has a version, which `read_file` gives. Replacing a file takes the version it was read
at, so two writers never lose each other's work:

- `write_file` over a file that exists, with no version, is refused as `exists`: the agent reads it
  first.
- A version that is no longer the file's is refused as `conflict`: the file changed since it was
  read, and the agent reads it again.

Appending, editing and deleting need no version. Each is made over what the file holds at that
moment, and tried again if another writer gets there first.

A file keeps who last wrote it and when, and nothing older: there is no history of a file.

## Sharing trees

`workspace` shares other trees with an agent, each seen under `shared/<name>/`:

```yaml
tools: [files]
workspace:
  shared:
    team: acme                                  # read and written
    runbooks: {tree: acme/runbooks, mode: read}
```

A tree is named `org`, `org/name` or `org/@user/name`, and is reachable by the agents under the scope
its name begins with:

| Tree | Reachable by |
| --- | --- |
| `acme` | every agent of `acme` |
| `acme/runbooks` | every agent of `acme` |
| `acme/@jon/notes` | the agents of `acme` that work for `jon` |

An agent file that shares a tree its agent cannot reach does not read, and says which tree and why.
A tree holds only its own files: `acme` does not hold `acme/runbooks`, so a tree shared only to
read stays that way however the trees above it are shared.

`mode: read` shares a tree to read, list and search. Writing, editing or deleting in it is refused
as `read_only`.

## Read into every turn

`context` names files the agent is shown as each turn begins:

```yaml
tools: [files]
context: [SOUL.md, MEMORY.md, shared/team/CONVENTIONS.md]
```

They are added to its system prompt under `# Your workspace`, each with the version `read_file`
would give, so the agent can change one without reading it again. They are read once, as the turn
begins: what the agent writes during a turn is in the next one.

The agent is also told:

- the names of the other files and folders at the top of its own tree, up to 50, which it reads
  when it needs them;
- the trees shared with it, and which of them are only to read;
- which of its `context` files are not written yet.

A `MEMORY.md` the agent keeps is there to find in every turn, and the files it keeps beside it cost
only their names.

### How much is read

Up to 16 KB of the files' contents is read into each turn, and `max_bytes` sets another amount, from
1,024 to 262,144 bytes. Up to 20 files can be named.

```yaml
context:
  files: [SOUL.md, MEMORY.md]
  max_bytes: 65536
```

The budget is shared out smallest file first, so room a short file does not use goes to the longer
ones. A file longer than its share is read from its start and its end, with a line saying how much
is left out between them. A log kept by appending keeps its newest lines in view.

When a file in the agent's own tree is cut this way, the agent is asked to rewrite it shorter: to
fold what is older into a summary, and keep what is only a record in files of their own, by date.
A file in a shared tree is read the same way, but the agent is not asked to change it.

## Content from outside

A file keeps the labels of the turns that wrote it: one written by a turn that had read content from
outside, such as a page `web_search` found or an issue an MCP server returned, is labelled
`outside`. Appending to a labelled file, or editing it, keeps its labels, since what was there
before is there still; writing it over replaces them with those of the turn that wrote it.

Reading a labelled file, or listing or finding it, labels the reading turn the same way, and so
does a `context` file. Once a turn carries `outside`, a gated tool's calls wait on a person, in
that turn and the ones after it, until the agent's conversation is cleared. See
[Policy and approvals](/concepts/policy/).

A policy names a file tool's call by its path, or by the glob for `list_files` and `search_files`:

```yaml
allow: [write_file(notes/*)]
deny: [delete_file(*)]
```

No file tool is gated.

## Seeing an agent's files

The CLI and the HTTP API do not read or write an agent's files: ask the agent, which reads and
writes them with its tools. A tree belongs to its agent's key rather than to the running agent, so
an agent removed and started again under the same key finds its files where it left them.

Files are kept in the store's `files` namespace, under the tree and the path: an agent's
`MEMORY.md` is `agents/acme/@jon/triage//MEMORY.md`. See [Storage](/run/storage/).
