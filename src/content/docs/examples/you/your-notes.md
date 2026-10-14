---
title: Your notes
description: "A research assistant that reads the web for you and files what it learns into your notes folder."
sidebar:
  order: 3
---

Ask this agent a question and it researches it, then writes what it found into your notes folder:
a note per topic, with sources, linked to what you already have. Later, ask it what you know about
something, and it answers from your notes first.

Your notes stay files in a folder, so Obsidian, or any editor, works with them as before.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key;
- a key for `web_search`;
- [Node.js](https://nodejs.org/) for the filesystem server, and a notes folder, here
  `~/Notes`.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
mcp:
  notes:
    command: npx
    args: [-y, "@modelcontextprotocol/server-filesystem", /home/jo/Notes]
```

The [filesystem server](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem)
reaches only the folders its arguments name.

### The policy

```yaml title="~/.config/wardrik/policies/notes.yaml"
allow_after:
  outside:
    - notes/write_file
    - notes/edit_file
    - notes/create_directory
deny:
  notes/move_file: Notes stay where you put them.
budget:
  usd: 2.00
  per: day
```

- **It writes notes even after reading the web.** Writing into your own notes folder is the job.
- **It never moves or renames,** so your links don't break.
- **A daily budget** caps what its research spends.

### The agent

```markdown title="~/.config/wardrik/agents/notes.md"
---
description: Researches what I ask and files it into my notes.
tools: [web_search, notes/*]
policy: notes
---
You keep my notes in /home/jo/Notes. Before researching, search my notes for what I already know.

When you research, write a note per topic: a summary, the key facts, and sources as links. Link
to related notes I already have with [[Note name]]. Edit an existing note rather than writing a
second one on the same thing.

When I ask what I know about something, answer from my notes, and say which ones.
```

## Try it

```sh
wardrik reload
wardrik ask notes "Research heat pumps for a 1930s house: cost, noise, and grants in the UK."
wardrik ask notes "What do I know about heat pumps?"
```

The first answer comes with a new note in `~/Notes`. The second answers from it.

## What it shows

- **Tools on your own machine,** through an MCP server run as a command.
- **Writing after reading the web,** allowed exactly where you said.
- **Plain files** you keep using as you always have.

## Details

### Notes and outside content

The agent's notes are written from what it read on the web, so reading them back counts as outside
content too: the filesystem server isn't marked `trusted`, and that's right for notes a web page
could have shaped. Here it changes nothing, since the agent can only write notes. An agent with
more power should use its own [files](/concepts/files-and-memory/), which keep the label of what
the turns that wrote them had read.

### Obsidian

To work through Obsidian itself, use
[mcp-obsidian](https://github.com/MarkusPfundstein/mcp-obsidian), which needs Obsidian's Local REST
API plugin. Its tools are named with an `obsidian_` prefix, such as `obsidian_simple_search` and
`obsidian_append_content`, so the policy names `obsidian/obsidian_append_content`, and so on.

### Taking it further

- Add a weekly [clock trigger](/build/triggers/) that tidies notes: merges duplicates, fixes links.
- Give it `deep_research` for the questions worth a long read.
