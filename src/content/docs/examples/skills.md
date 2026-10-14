---
title: An agent that writes its own skills
description: An agent that writes down how it did each task as a skill, reads them next time, and tidies them weekly.
sidebar:
  order: 3
---

After each task worth repeating, this agent writes down how it did it as a skill, and reads it first
next time. Weekly, it tidies its skills. It's just files, an index read every turn, and a trigger.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key from the
  [Quickstart](/getting-started/quickstart/#1-install);
- a key for `web_search`.

## The agent

```markdown title="~/.config/wardrik/agents/researcher.md"
---
description: Researches and writes up, and keeps a skill for each kind of task it has done.
model: anthropic:claude-sonnet-5
tools: [files, web_search, deep_research, run_lua]
context: [SKILLS.md, MEMORY.md]
compaction: {at: 0.5, keep: 0.2}
triggers:
  - name: tidy
    every: "0 3 * * 0"        # Sundays, 03:00 UTC
    prompt: >-
      Tidy your skills. Read each one in skills/, merge those that overlap, fix what this week's work
      showed was wrong, and remove those you have not used and do not expect to. Keep SKILLS.md to
      what is in skills/.
policy:
  ask:
    delete_file(skills/*): This deletes a skill.
  budget: {usd: 5.00, per: day, on_exhausted: ask}
---
You research and write up for a small team.

SKILLS.md is the index of what you know how to do. Before a task, read the skill that fits it, and
follow it.

After a task that took more than a few steps and may come again, write what worked as a skill, in
skills/<name>/SKILL.md: a front matter with its name and a one-line description, then the steps,
what to check, and what went wrong. Add a line for it to SKILLS.md, with its path and when to use
it. When a skill leads you wrong, fix it then, not later.
```

## Try it

Give it the same kind of task twice:

```sh
wardrik reload
wardrik ask researcher "Find this year's three most cited papers on retrieval-augmented generation, and summarise each in a paragraph with its link."
wardrik ask researcher "What skills do you have now?"
wardrik ask researcher "Do the same for speculative decoding."
```

`wardrik watch researcher` during the third turn shows it reading the skill before searching.

## What it shows

- **Files read when needed.** Only the index is in every turn. See
  [Files and memory](/concepts/files-and-memory/).
- **A trigger that keeps it in shape.** The Sunday run is a message on a clock. See
  [Trigger an agent](/build/triggers/).
- **A long life.** It summarises its older history before it outgrows the context window;
  `compaction` sets when. What it must not forget goes in a skill or `MEMORY.md`. See
  [A history that grows](/concepts/durable-runs/#a-history-that-grows).
- **Rules over its own files.** Deleting a skill waits for a person; writing one doesn't. See
  [What a call acts on](/concepts/rules/#what-a-call-acts-on).
- **Skills remember their source.** A skill written after reading a web page carries that label, so
  a page can't plant instructions for later. See [Content from outside](/concepts/outside-content/).

## Details

### Taking it further

- **One team's skills.** One agent writes a shared tree; the others read it under `shared/skills/`.
  `config.yaml`'s [`workspace.shared`](/reference/config/#workspace) must let them mount it:

  ```yaml
  # the agent that writes them
  workspace:
    shared:
      skills: acme/skills

  # every other agent of acme
  workspace:
    shared:
      skills: {tree: acme/skills, mode: read}
  context: [shared/skills/SKILLS.md]
  ```

- **A night's lessons.** A second trigger at 02:00 can ask it to keep the day's lessons in
  `MEMORY.md` before the history is summarised.
