---
title: Watch your competitors
description: An agent that watches your competitors' feeds and posts to a Slack channel when they change, checks what has no feed once a week, talks it over with the team in the thread, and changes what it looks for as they tell it.
sidebar:
  order: 6
---

An agent for a team that wants to know what its competitors are doing without anyone having to look.
It reads their changelogs, their blogs and a Google Alert every half hour, and when one of them has
something new, posts a brief to `#competitors`. Once a week it follows a checklist it keeps for
itself, for what has no feed, such as pricing pages. Anyone can reply under a brief to ask what
something means or to tell it what to watch, and it changes its checklist to suit. On Fridays it
looks back over the week.

It only searches and writes its own notes, so it needs no approvals: nothing it reads can get it to
change anything outside its files.

## What it takes

- the daemon, [installed](/getting-started/install/) and running, with a model provider's key as the
  [Quickstart](/getting-started/quickstart/#1-install) gives it one;
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
  - name: news
    every: 30m
    feed:
      - https://rivalco.example/changelog.rss
      - https://billwise.example/blog/atom.xml
      - https://www.google.com/alerts/feeds/0123456789/0123456789
    prompt: New in the feeds you watch, below.
  - name: sweep
    every: "0 8 * * 1"        # 08:00 UTC on Mondays
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
each. HEARTBEAT.md is your own checklist for the Monday sweep: what has no feed, such as pricing
and home pages, and what to search for. Keep both current.

When you are handed new entries from the feeds, or on a sweep, keep only what someone on the team
would be sorry to miss: launches, pricing, positioning, and the hires and partnerships that say
where a competitor is going. notes/ holds what you have found, a file per competitor; add each
finding to its competitor's file, with the date and a link.

Answer with the brief: under each competitor's name, a line per finding with its link, then at
most three lines on what it means for us. If nothing matters, answer "Nothing worth posting." in
one line. Write the brief to LATEST.md as well, so you know what you last posted. When you find a
competitor's feed, say which, so someone can add it to your news trigger.

In a Slack thread, someone is replying to what you posted, which LATEST.md holds. Answer from your
notes, and search when they ask something they do not hold. When someone tells you what they
want more or less of, change WATCHLIST.md or HEARTBEAT.md, and say what you changed.
```

- `feed` reads the three feeds every half hour, and asks the agent only when one has entries it
  has not seen, with them under the prompt. A half hour with nothing new costs three requests and
  no model call. See [Watching a feed](/build/triggers/#watching-a-feed) for where to find a
  competitor's feeds, and how to make a Google Alert one.
- `prompt_file` asks the agent, each Monday, to read `HEARTBEAT.md` and do what it says as it
  stands then. The agent writes that file itself, so what it checks changes as the team tells it
  to, and as the Friday review finds what is worth looking at. See
  [A checklist the agent can edit](/build/triggers/#a-checklist-the-agent-can-edit).
- `context` reads `WATCHLIST.md` and `LATEST.md` into every turn, so a reply in a thread knows what
  the brief above it said.
- `notify` posts what each triggered run answers to `#competitors`. A conversation in a thread
  answers in its thread, and posts nothing else.
- `channels` offers the agent in Slack, so it answers in the channel's threads.
- The budget stops it for the day once it has spent $3, rather than asking. See
  [Budgets](/concepts/budgets/).

Read the agent files again, and tell it who to watch:

```sh
wardrik reload
wardrik ask competitors "We are Acme, invoicing software for small agencies. Our competitors
are Rivalco (rivalco.com) and Billwise (billwise.io). Watch their pricing, what they launch
and who they hire. Write WATCHLIST.md, and a HEARTBEAT.md for your Monday sweeps."
wardrik ask competitors "Do this week's sweep now."
```

Each answer is posted to `#competitors` as well. The news trigger's first run only notes what the
feeds already hold, so its first brief comes with the next entry one of them adds.
`wardrik triggers` says when each runs next, and how each last ran.

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
> ↳ **maria:** Stop following their hiring. Look at their pricing page every Monday instead.
> ↳ **Wardrik:** Done. I took hiring out of WATCHLIST.md, and HEARTBEAT.md now checks
> rivalco.com/pricing on Mondays.

Each thread is a conversation of its own, and every thread and every run share the agent's files,
so what one thread changes, the next run follows. **Answer every message**, under the app's
message in the channel, has the agent answer anything posted there, with no mention. See
[Threads in Slack](/channels/slack/#threads-in-slack).

## What it shows

- **Feeds that cost nothing until they change.** The agent is asked only when a feed has
  something new, so watching every half hour is cheap.
- **A trigger that follows its own checklist.** The agent writes `HEARTBEAT.md`, and each run
  reads it as it stands, so what it does changes without anyone editing its file.
- **Posting and conversing in one place.** Triggered runs post to a room as notices; replies in the
  room are threads the agent answers. See [Send notices](/build/notices/) and
  [Channels](/channels/).
- **Memory in files.** Its notes, its watchlist and its last brief are files every conversation
  shares. See [Files and memory](/concepts/files-and-memory/).
- **Nothing to approve.** Its only tools search and write its own files, so what a feed or a web
  page says can mislead its notes at worst. Give it a tool that acts, such as posting to a CRM, and that tool's
  calls ask a person once it has read the web. See
  [Content from outside](/concepts/outside-content/).

## Taking it further

- Hand a question to several researchers at once with `deep_research` in its tools, for a Friday
  review that goes deeper than a sweep can. See [Delegation](/concepts/agents/#delegation).
- Share a tree with the team's other agents, `workspace: {shared: {team: acme}}`, and have it keep
  a battlecard for each competitor in `shared/team/` for sales to read.
