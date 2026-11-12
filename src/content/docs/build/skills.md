---
title: Skills
description: "Give agents instructions for kinds of tasks as SKILL.md files, which they find and read when a task needs them."
sidebar:
  order: 5.5
---

A skill tells an agent how to approach one kind of task: which tools to use, in what order, and
what a good result looks like. A skill is a `SKILL.md` file in the agent's
[workspace](/concepts/files-and-memory/). The agent finds its skills with `search_files` and reads
the one a task needs.

Skills use the [Agent Skills](https://agentskills.io) layout. A skill made only of instructions
works as it is.

## Write a skill

```markdown title="skills/issue-triage/SKILL.md"
---
name: issue-triage
description: Triage a new GitHub issue, find duplicates and suggest labels.
---
Search open and closed issues for the error message before anything else.
Name a duplicate only when the steps to reproduce match. Suggest at most two labels.
```

- Put each skill in its own directory: `skills/<name>/SKILL.md`. Files a skill refers to go beside it.
- `description` says when to use the skill. The agent reads it to choose.
- A skill holds instructions only. Nothing in it runs. Work a script would do belongs in a
  [tool](/build/tool-workers/) or an [MCP server](/build/mcp/).
- A skill can't give an agent tools. The agent's `tools` and `policy` still decide what it can do.

## Give an agent skills

Keep skills in a directory, such as one in git, and sync it into the agent's workspace:

```sh
wardrik agent files sync triage ./skills --to skills
```

Tell the agent to look for skills in its instructions:

```markdown title="~/.config/wardrik/agents/triage.md"
---
tools: [files, github/*]
---
Before a task, run search_files for `^description:` in `skills/*/SKILL.md`. Read the skill that
fits the task, and follow it.
```

```sh
wardrik reload triage
```

`search_files` returns the `description` line of every skill in one call. The agent reads only the
skill it needs.

## Share skills between agents

Keep shared skills in one agent's workspace and mount it read-only in the others:

```yaml title="~/.config/wardrik/agents/triage.md"
tools: [files]
workspace:
  shared:
    skills: {agent: agent:skills, mode: read}
```

```sh
wardrik agent files sync skills ./skills --delete
```

Tell each agent to search `shared/skills/*/SKILL.md` too. `config.yaml` sets who can mount the
workspace. See [Sharing workspaces](/concepts/files-and-memory/#sharing-workspaces).

## Let an agent write skills

An agent with `files` can write skills of its own. Require approval for each one:

```yaml
policy:
  ask: ["write_file(skills/*)", "edit_file(skills/*)"]
```

A skill written in a turn that read [outside content](/concepts/outside-content/) is labeled
`outside`. Reading it labels the agent's turn too, so instructions from outside content can't come
back later as a trusted skill.
