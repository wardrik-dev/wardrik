---
title: The front door
description: "The agent wardrik init writes: ask it for an outcome, approve its plan, and it runs the work."
sidebar:
  order: 0.5
---

`wardrik init` writes one agent, `assistant`: the front door. Tell it an outcome, and it proposes
the work as the tool calls that do it. Approve them, and the work runs on its own. You never write
an agent file for it.

## Ask for an outcome

```sh
wardrik ask assistant "Tell me when https://elixir-lang.org/atom.xml has a new post"
```

It answers with its plan, then proposes the call that carries it out:

```text
I'll set up a watcher on that feed. Plan:

• A worker, elixir-blog-watch, checks the Elixir blog's feed every 30 minutes. A feed check costs
  nothing until a new post appears, so this runs cheap.
• When a new post lands, it keeps a line about it — title, link, and what it says — in its
  history, and I'll pass the news to you here when you ask me what came of it.

  → agents_list
  ✓ agents_list
Nothing runs for this yet, so I'll define a new worker.
Waiting on a person for 1 call:
  ? agent_define  call_8d2ebbfe28aa4ee1a269dee2  agent_define is gated, so it a…
wardrik approve default/assistant, or deny, decides it.
```

Approve the call, and it runs as the front door wrote it. Or deny it with a reason, and the front
door proposes again:

```sh
wardrik approve assistant call_8d2ebbfe28aa4ee1a269dee2
wardrik deny assistant call_8d2ebbfe28aa4ee1a269dee2 "Once an hour is enough."
```

`wardrik parked` lists what waits, without arguments, so the front door's plan says what each call
does. Slack and the [webhook](/build/notices/#webhooks) show arguments. See
[Approvals](/concepts/approvals/).

## See what runs

The front door sets up standing work as workers: agents of your org, with the triggers that start
them. They're agents like any other:

```sh
wardrik ls                  # each worker, when it runs next, what it has spent today
wardrik triggers            # when each runs next, and how it last ran
wardrik show elixir-blog-watch
```

Or ask the front door, "What are you doing for me?"

## Change and retire work

Say it in plain words: "check it every two hours instead", "stop watching the Elixir blog". Each
change is a call it proposes and you approve. Stopping a worker removes its triggers, so it spends
nothing; `wardrik agent rm NAME` removes it for good.

It proposes changes of its own too, such as a check that has found nothing for weeks.

## Where results go

A worker's answers are kept in its history. Ask the front door what came of a piece of work, or run
`wardrik history NAME`. See [Delegate to other agents](/build/delegation/).

## What it may do

`init` writes `~/.config/wardrik/agents/assistant.md` with the model you chose:

```markdown title="~/.config/wardrik/agents/assistant.md"
---
description: "The front door: turns what people ask for into work that runs."
model: anthropic:claude-sonnet-5
tools: [self/*, agents/*, files, web_search]
context: [MEMORY.md]
policy: {budget: {per: day, tokens: 2000000}}
idle_timeout: infinity
---
You are Wardrik, the one place the people of this org come to get things done. …

# Playbook
…
```

- **`agents/*`** lets it read the agents of its org, hand them tasks, define workers and change their
  triggers. Reads run freely; each change waits on a person.
- **`files`** gives it a tree of files; `MEMORY.md` is read into every turn.
- **The budget** allows 2,000,000 tokens a day, then asks. Every worker it defines is held to the
  same policy and budget.

To let it hand tasks to its workers without asking, allow the tool by name:

```yaml
policy:
  allow: [agent_ask]
  budget: {per: day, tokens: 2000000}
```

## Its playbook

The body of `assistant.md` is its instructions, then a playbook: shapes of work that run well, from
a feed watch to a morning brief, each with the triggers and budget it suits. Edit it to fit your org,
then `wardrik reload`. `init` writes the file only where there is none, so your changes survive.

## In Slack

Add `channels: [slack]` to its file, and it answers in the Slack rooms its app is invited to, asking
there before each call. See [Slack](/channels/slack/).

## Details

- `wardrik ask` follows the turn until it waits on you.
- A task it hands a worker comes back to it as a message, which it passes on.
- `self/*` lets it read its own definition.
- `MEMORY.md` holds who it works for, what they want more or less of, and the work it set up and why.
- `web_search` works once `config.yaml` gives it a key, as
  [`brave.api_key`](/reference/config/#brave), for every agent. A search without one tells the front
  door the key is missing, and it tells you.
- The budget counts tokens because a dollar budget refuses a model the catalog can't price, such as
  one a subscription pays for. Where yours is priced, `usd: 3.00` counts dollars instead. Workers'
  spend is held to the front door's budget ahead of their own, counted on their own. See
  [Budgets](/concepts/budgets/).
- Workers run the model `config.yaml`'s `defaults` give.
- Once it has read content from outside, as its workers' web findings are, an `allow` rule stops
  counting and each call waits again. See [Content from outside](/concepts/outside-content/).
