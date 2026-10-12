---
title: Watch your competitors
description: An agent that researches your competitors each weekday, posts what changed to a Slack channel, talks it over with the team in the thread, and changes what it looks for as they tell it.
sidebar:
  order: 6
---

An agent for a team that wants to know what its competitors are doing without anyone having to look.
Each weekday morning it follows a checklist it keeps for itself, searches for what changed, and posts
a brief to `#competitors`. Anyone can reply under a brief to ask what something means or to tell it
what to watch, and it changes its checklist to suit. On Fridays it looks back over the week.

It only searches and writes its own notes, so it needs no approvals: nothing it reads can get it to
change anything outside its files.

## What it takes

- the daemon, [installed](/getting-started/install/) and running, with a model provider's key as the
  [Quickstart](/getting-started/quickstart/#set-it-up) gives it one;
- a key for `web_search`, where the daemon reads its keys;
- a Slack app with a bot token and an app-level token, made as
  [Slack](/channels/slack/#a-slack-app) makes one, and a Slack channel for it, here
  `#competitors`.

## The channel

Name the Slack app in `config.yaml`, and `#competitors` as a room to post in:

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}

notify:
  competitors:
    channel: slack
    room: "#competitors"
```

Restart the daemon, which reads `config.yaml` as it starts:

```sh
systemctl --user restart wardrik
wardrik doctor
```

## The agent

```markdown title="~/.config/wardrik/agents/competitors.md"
---
description: Researches our competitors, posts what changed, and talks it over in the thread.
model: anthropic:claude-sonnet-5
tools: [web_search, files]
context: [WATCHLIST.md, LATEST.md]
channels: [slack]
triggers:
  - name: sweep
    every: "0 8 * * 1-5"      # 08:00 UTC, Monday to Friday
    prompt_file: HEARTBEAT.md
  - name: review
    every: "0 15 * * 5"       # 15:00 UTC on Fridays
    prompt: >
      Look back over this week's findings in notes/. Write a short review of what our
      competitors did and what it means for us. Then tidy HEARTBEAT.md: drop checks that
      have found nothing for weeks, and add what this week suggests looking at.
notify: {to: [competitors], on: [finished, failed]}
policy:
  deny:
    delete_file(*): Keep what you have written.
  budget: {usd: 3.00, per: day, on_exhausted: deny}
---
You research our competitors for the team in #competitors.

WATCHLIST.md says who we are, who our competitors are, and what the team wants to know about
each. HEARTBEAT.md is your own checklist for each morning's sweep: what to search for, on which
days, and why. Keep both current.

On a sweep, follow HEARTBEAT.md. notes/ holds what you have found, a file per competitor; check
each thing you find against it, and keep only what is new and what someone on the team would be
sorry to miss: launches, pricing, positioning, and the hires and partnerships that say where a
competitor is going. Add each to its competitor's file, with the date and a link.

Answer with the brief: under each competitor's name, a line per finding with its link, then at
most three lines on what it means for us. If nothing is new, answer "Nothing new." Write the
brief to LATEST.md as well, so you know what you last posted.

In a Slack thread, someone is replying to what you posted, which LATEST.md holds. Answer from your
notes, and search when they ask something they do not hold. When someone tells you what they
want more or less of, change WATCHLIST.md or HEARTBEAT.md, and say what you changed.
```

- `prompt_file` asks the agent, each weekday, to read `HEARTBEAT.md` and do what it says as it
  stands then. The agent writes that file itself, so what it checks changes as the team tells it
  to, and as the Friday review finds what is worth looking at. See
  [A checklist the agent can edit](/guides/triggers/#a-checklist-the-agent-can-edit).
- `context` reads `WATCHLIST.md` and `LATEST.md` into every turn, so a reply in a thread knows what
  the brief above it said.
- `notify` posts what each triggered run answers to `#competitors`. A conversation in a thread
  answers in its thread, and posts nothing else.
- `channels` offers the agent in Slack, so it answers in the channel's threads.
- The budget stops it for the day once it has spent $3, rather than asking. See
  [Budgets](/concepts/policy/#budgets).

Read the agent files again, and tell it who to watch:

```sh
wardrik reload
wardrik ask competitors "We are Acme, invoicing software for small agencies. Our competitors
are Rivalco (rivalco.com) and Billwise (billwise.io). Watch their pricing, what they launch
and who they hire. Write WATCHLIST.md, and a HEARTBEAT.md for your morning sweeps."
wardrik ask competitors "Do this morning's sweep now."
```

Each answer is posted to `#competitors` as well; the second is what each weekday morning brings.
`wardrik triggers` says when it runs next.

## In Slack

With the daemon running, invite the app to `#competitors`:

```
/invite @yourapp
```

The app says the agent answers there now. Reply under a brief, mentioning the app, and the agent
answers in that thread; once it has, replies in the thread reach it without a mention:

> **Wardrik:** **Rivalco** · Launched a free plan for teams of up to three. rivalco.com/pricing …
> ↳ **maria:** @Wardrik what does their free plan mean for our starter plan?
> ↳ **Wardrik:** Their free plan covers what our starter plan sells for $12 …
> ↳ **maria:** Stop following their hiring. Read their changelog every Monday instead.
> ↳ **Wardrik:** Done. I took hiring out of WATCHLIST.md, and HEARTBEAT.md now checks
> rivalco.com/changelog on Mondays.

Each thread is a conversation of its own, and every thread and every sweep share the agent's files,
so what one thread changes, the next sweep follows. **Answer every message**, under the app's
message in the channel, has the agent answer anything posted there, with no mention. See
[Threads in Slack](/channels/slack/#threads-in-slack).

## What it shows

- **A trigger that follows its own checklist.** The agent writes `HEARTBEAT.md`, and each run
  reads it as it stands, so what it does changes without anyone editing its file.
- **Posting and conversing in one place.** Triggered runs post to a room as notices; replies in the
  room are threads the agent answers. See [Send notices](/guides/notices/) and
  [Channels](/channels/).
- **Memory in files.** Its notes, its watchlist and its last brief are files every conversation
  shares. See [Files and memory](/concepts/files-and-memory/).
- **Nothing to approve.** Its only tools search and write its own files, so what a web page says
  can mislead its notes at worst. Give it a tool that acts, such as posting to a CRM, and that tool's
  calls ask a person once it has read the web. See
  [Content from outside](/concepts/policy/#content-from-outside).

## Taking it further

- Hand a question to several researchers at once with `deep_research` in its tools, for a Friday
  review that goes deeper than a sweep can. See [Delegation](/concepts/agents/#delegation).
- Share a tree with the team's other agents, `workspace: {shared: {team: acme}}`, and have it keep
  a battlecard for each competitor in `shared/team/` for sales to read.
