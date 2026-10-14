---
title: An agent that writes its own skills
description: An agent that writes down how it did each task worth repeating as a skill, reads the index of its skills in every turn, and tidies them once a week.
sidebar:
  order: 3
---

An agent that gets better at the work it is given. After a task worth repeating it writes down
how it did it, as a skill in a file of its own, and the next time it reads that skill first. Once a
week it reads them all again, merges the ones that overlap and fixes the ones that led it wrong.

Nothing here is a feature of its own: it is files, a file read into every turn, and a trigger.

## What it takes

- the daemon, [installed](/getting-started/install/) and running, with a model provider's key as the
  [Quickstart](/getting-started/quickstart/#1-install) gives it one, and a key for
  `web_search`.

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

`SKILLS.md` is read into every turn, and the skills themselves are not: the agent reads one when it
needs it, so a hundred skills cost a hundred lines of index. Read the agent files again, and give it
something to do twice:

```sh
wardrik reload
wardrik ask researcher "Find this year's three most cited papers on retrieval-augmented generation, and summarise each in a paragraph with its link."
wardrik ask researcher "What skills do you have now?"
wardrik ask researcher "Do the same for speculative decoding."
```

Follow the third turn with `wardrik watch researcher` in another terminal, and look for its
`read_file` of the skill the first one wrote, before it searches.

## What it shows

- **Files, read in when needed.** `context` reads only the index into each turn, and the agent
  reads a skill with `read_file` when it fits. A file longer than its share of the turn is read from
  its start and its end, and the agent is asked to fold it shorter. See
  [Files and memory](/concepts/files-and-memory/).
- **A trigger that keeps it in shape.** The Sunday run is an ordinary message on a clock, in the
  agent's history like any other. See [Trigger an agent](/build/triggers/).
- **A long life.** The agent keeps one conversation for as long as it runs, and summarises the older
  part with its own model before it outgrows the context window: `compaction` sets when. What it
  must not forget belongs in a skill or `MEMORY.md`, which no summary touches. See
  [A history that grows](/concepts/durable-runs/#a-history-that-grows).
- **Rules over its own files.** `delete_file(skills/*)` names the calls that delete a skill, so
  deleting one waits on a person while writing them does not. See
  [What a call acts on](/concepts/rules/#what-a-call-acts-on).
- **Where a skill came from.** A file keeps whether the turn that wrote it had read content from
  outside, such as a page `web_search` found. A turn that reads such a skill counts as having read
  that content too, so a page cannot leave instructions in a skill that a gated tool then follows
  with nobody asked. See [Content from outside](/concepts/outside-content/).

## Taking it further

- **One team's skills.** Keep the skills in a shared tree, written by one agent and read by the
  others, each of which sees it under `shared/skills/`:

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

- **A night's lessons.** A second trigger at 02:00 can ask it to read the day's conversation
  back and keep what it learned in `MEMORY.md`, before the history is summarised away.
