---
title: Files and memory
description: "An agent keeps a tree of files in the store, shares trees with other agents, and reads chosen files into every turn."
sidebar:
  order: 5
---

An agent with `files` in its tools has a tree of files of its own. The tree is kept in the store, so
its notes survive the node it was on. Name a file in `context`, and the agent reads it at the start
of every turn: that's its memory.

```yaml
tools: [files]
context: [MEMORY.md]
```

## The file tools

| Tool | What it does |
| --- | --- |
| `read_file` | Reads a file, with its version, numbered by line |
| `write_file` | Writes a file, or appends with `append` |
| `edit_file` | Replaces text that appears once, or everywhere with `all` |
| `list_files` | Lists the files a glob matches, newest first |
| `search_files` | Finds the lines a regular expression matches |
| `delete_file` | Deletes a file |

A path is relative to the top of the tree, such as `notes/2026-10-01.md`. Folders are only the
beginnings of paths, so there's nothing to create first.

## Writing over what was read

Every file has a version, which `read_file` gives. Replacing a file takes the version it was read
at, so two writers never lose each other's work. A stale write is refused, and the agent reads the
file again. Appending, editing and deleting need no version.

## Sharing trees

`workspace` shares other trees with an agent, each seen under `shared/<name>/`:

```yaml
tools: [files]
workspace:
  shared:
    team: acme                                  # read and written
    runbooks: {tree: acme/runbooks, mode: read}
```

| Tree | Reachable by |
| --- | --- |
| `acme` | `acme`'s own agents, none that work for a user |
| `acme/runbooks` | `acme`'s own agents |
| `acme/@jon/notes` | the agents of `acme` that work for `jon` |

Anyone else mounts a tree only where `config.yaml` shares it, by resource pattern:

```yaml title="~/.config/wardrik/config.yaml"
org: acme

workspace:
  shared:
    acme/runbooks:
      read: ["acme/*"]                             # every agent in acme may read it
      write: [acme/agent/ops, "acme/agent/ops/*"]  # and acme's ops agent, in every thread, change it
```

## Read into every turn

`context` files are added to the system prompt as each turn begins, under `# Your workspace`. The
agent is also told the names of the other files at the top of its tree, which it reads when needed.
So a `MEMORY.md` is always in view, and the files beside it cost only their names.

```yaml
context:
  files: [SOUL.md, MEMORY.md, shared/team/CONVENTIONS.md]
  max_bytes: 65536
```

Up to 16 KB is read unless `max_bytes` says otherwise. A file longer than its share is read from its
start and its end, and the agent is asked to rewrite it shorter.

## Content from outside

A file written by a turn that had read [content from outside](/concepts/outside-content/) keeps the
`outside` label. A turn that reads it later carries the label too, so nothing an outsider leaves in
the agent's notes gets around the policy.

## Details

- **Limits.** A file is text, at most 4 MiB. `read_file` reads at most 2,000 lines or 128 KB a call;
  `offset` and `limit` read the rest. `list_files` returns at most 500, with each file's size, when
  it was written and by whom. `search_files` returns at most 200 matches, with up to 5 lines around
  each.
- **Paths.** One that begins with `/` or `~`, or holds `..`, is refused. In a glob, `*` matches
  within one folder, `**` across folders and `?` one character. `*` in `tools` gives the file tools
  too.
- **Errors.** A tool that can't do what it was asked answers the model with
  `{"ok": false, "error": {"code": ..., "message": ...}}`, and the turn carries on.
- **Versions.** `write_file` over an existing file with no version is refused as `exists`. A
  version that's no longer the file's is refused as `conflict`. Appends, edits and deletes are made
  over what the file holds at that moment, and tried again if another writer gets there first. A
  file keeps who last wrote it and when, and nothing older.
- **Tree names.** A tree is named `org`, `org/name` or `org/@user/name`. A tree holds only its own
  files: `acme` doesn't hold `acme/runbooks`. An agent shared a tree to read mounts it with
  `mode: read`; writing, editing or deleting in it is refused as `read_only`. An agent file that
  shares a tree its agent can't reach doesn't read, and says which tree and why. `acme/*` is every
  agent in `acme`, its users' included.
- **Context.** Files are read once, as the turn begins: what the agent writes during a turn is in the
  next one. Each comes with the version `read_file` would give, so the agent can change one without
  reading it again. The agent is told up to 50 names at the top of its tree, the trees shared with
  it and which are read-only, and which `context` files aren't written yet.
- **Context budget.** `max_bytes` ranges from 1,024 to 262,144. Up to 20 files can be named. The
  budget is shared out smallest file first; a cut file shows a line saying how much is left out, so
  a log kept by appending keeps its newest lines in view. The agent is asked to fold older material
  into a summary and keep records in dated files. A file in a shared tree is cut the same way, but
  the agent isn't asked to change it.
- **Labels.** Appending to or editing a labelled file keeps its labels; writing it over replaces them
  with the writing turn's. Listing or finding a labelled file labels the turn too, as does a
  `context` file. The label lasts until the conversation is cleared.
- **Policy on files.** A rule names a file tool's call by its path, or by the glob for `list_files`
  and `search_files`, as in `allow: [write_file(notes/*)]`. No file tool is gated. See
  [Writing rules](/concepts/rules/#what-a-call-acts-on).
- **Seeing an agent's files.** The CLI and the HTTP API don't read or write them; ask the agent. A
  tree belongs to the agent's key, so an agent removed and started again under the same key finds
  its files. Files are kept in the store's `files` namespace: an agent's `MEMORY.md` is
  `agents/acme/@jon/agent/triage//MEMORY.md`. See [Storage](/run/storage/).
