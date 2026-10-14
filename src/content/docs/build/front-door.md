---
title: The front door
description: The agent wardrik init writes, the one place to ask for what you want. It proposes the work, you approve it, and it defines and runs the agents that do it, so nobody writes their files by hand.
sidebar:
  order: 0.5
---

`wardrik init` writes one agent, `assistant`, and it is the front door: the one place to ask for
what you want. Tell it an outcome, such as keeping an eye on a blog or a brief each morning, and it
says its plan in plain words and proposes the work as the tool calls that do it. Once you approve
them, the work runs on its own. It sets up standing work as workers, agents of your org that it
defines with the triggers that start them, and it changes or retires them as you tell it. You never
write a file for them, and need not think about agents at all.

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

`wardrik ask` follows the turn until it waits on you. Approve the call, and it runs as the front
door wrote it:

```sh
wardrik parked
wardrik approve assistant call_8d2ebbfe28aa4ee1a269dee2
```

Or refuse it, saying why, and the front door reads the reason and proposes again:

```sh
wardrik deny assistant call_8d2ebbfe28aa4ee1a269dee2 "Once an hour is enough."
```

`wardrik parked` does not show a call's arguments, so the front door says in its plan what each call
does. A Slack notice and the [webhook](/build/notices/#webhooks) show them. See [Waiting on a person](/concepts/policy/#waiting-on-a-person).

## See what runs

The workers it defines are agents like any other, so `wardrik ls` lists them beside it, as
`default/elixir-blog-watch`, with when each runs next and what it has spent today:

```sh
wardrik ls
```

`wardrik triggers` says when each runs next and how it last ran, and `wardrik show NAME` shows one in
full. Or ask the front door, "What are you doing for me?", and it lists each piece of work, what it
watches, how often, how it last ran, and what it may spend.

## Change and retire work

Tell it in plain words: "check it every two hours instead", "less about hiring", "stop watching the
Elixir blog". Each change is a call it proposes and you approve. Stopping a worker removes its
triggers, so it never runs again and spends nothing; `wardrik agent rm NAME` removes it for good.

It proposes changes of its own too: a source one of its workers came across, a check that has found
nothing for weeks, a feed in place of a search on a clock. Each is the call that makes it, so
approving is all it takes.

## Where results go

A worker's answers are kept in its history. Ask the front door what came of a piece of work, and it
reads the worker and tells you; `wardrik history NAME` shows them as well. A task it hands a worker
comes back to it as a message, which it passes on. See
[Delegate to other agents](/build/delegation/).

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

- `agents/*` lets it list and read the agents of its org, hand them tasks, define workers and change
  their triggers; `self/*` lets it read its own definition. Reads run freely. Defining, asking and
  changing triggers are changes, so each waits on a person.
- `files` gives it a tree of files, and `context` reads its `MEMORY.md` into every turn: who it works
  for, what they want more or less of, and the work it has set up and why.
- `web_search` searches the web once its key is in the vault. A search made without one tells the
  front door which key it lacks, and it tells you.
- The budget allows 2,000,000 tokens a day, then waits on a person to approve more. Every worker it
  defines is held to the same policy and budget, ahead of its own definition's and counted on its
  own, so no worker can do or spend more than the front door may. It counts tokens because a budget
  in dollars refuses a model the catalog cannot price, such as one a subscription pays for; where
  yours is priced, `usd: 3.00` counts dollars instead. See [Budgets](/concepts/policy/#budgets).
- Workers run the model `config.yaml`'s `defaults` give, the one you chose where `init` wrote
  `config.yaml`.

To let it hand tasks to its workers without asking, allow the tool by name:

```yaml
policy:
  allow: [agent_ask]
  budget: {per: day, tokens: 2000000}
```

Once it has read content from outside, as its workers' findings from the web are, an `allow` rule
stops counting and each call waits on a person again. See
[Content from outside](/concepts/policy/#content-from-outside).

## Its playbook

The body of `assistant.md` is the front door's instructions, then its playbook: the shapes of work
that run well, from a feed watch and a weekly sweep that follows a checklist the worker keeps, to a
morning brief, a first response to incidents and acting on what a worker notices, each with the
triggers, instructions and budget it suits. Edit either to fit your org, such as the sources your
team reads or the MCP servers your deployment has, and read it again:

```sh
wardrik reload
```

`init` writes the file only where there is none, so it keeps your changes when it runs again.

## In a chat channel

Add `channels: [slack]` to its file, and it answers in the Slack rooms its app is invited to, as any
agent does, and each call it proposes is asked there with Approve and Deny. See
[Slack](/channels/slack/).
