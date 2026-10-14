---
title: Watch your competitors
description: An agent that posts what changed at your competitors to Slack, and changes what it watches as the team replies.
sidebar:
  order: 6
---

It reads competitors' feeds every half hour and posts what's new to `#competitors`. Mondays it checks
pages with no feed; Fridays it reviews the week. Reply in a thread to change what it watches. It only
searches and writes notes, so nothing needs approval.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key from the
  [Quickstart](/getting-started/quickstart/#1-install);
- a key for `web_search`;
- a [Slack app](/channels/slack/#a-slack-app) with a bot token and an app-level token, and a channel,
  here `#competitors`.

## The files

### config.yaml

The Slack app, and `#competitors` as a room to post in:

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

Restart the daemon:

```sh
systemctl --user restart wardrik
wardrik doctor
```

### The agent

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

- `feed` asks the agent only when there's something new. See
  [Watching a feed](/build/triggers/#watching-a-feed).
- `prompt_file` follows the `HEARTBEAT.md` it writes. See
  [A checklist the agent can edit](/build/triggers/#a-checklist-the-agent-can-edit).
- `context` gives a thread reply the last brief; `notify` posts runs; `channels` answers threads.
- The budget stops it at $3 a day. See [Budgets](/concepts/budgets/).

## Try it

Tell it who to watch:

```sh
wardrik reload
wardrik ask competitors "We are Acme, invoicing software for small agencies. Our competitors
are Rivalco (rivalco.com) and Billwise (billwise.io). Watch their pricing, what they launch
and who they hire. Write WATCHLIST.md, and a HEARTBEAT.md for your Monday sweeps."
wardrik ask competitors "Do this week's sweep now."
```

The first news brief comes with the next new feed entry. Invite the app to the channel:

```
/invite @yourapp
```

Mention the app under a brief, and it answers in the thread:

> **Wardrik:** **Rivalco** · Launched a free plan for teams of up to three. rivalco.com/pricing …
> ↳ **maria:** @Wardrik what does their free plan mean for our starter plan?
> ↳ **Wardrik:** Their free plan covers what our starter plan sells for $12 …
> ↳ **maria:** Stop following their hiring. Look at their pricing page every Monday instead.
> ↳ **Wardrik:** Done. I took hiring out of WATCHLIST.md, and HEARTBEAT.md now checks
> rivalco.com/pricing on Mondays.

Threads share the agent's files, so what one changes, the next run follows. See
[Threads in Slack](/channels/slack/#threads-in-slack).

## What it shows

- **Cheap watching:** a quiet feed costs no model call.
- **A checklist it maintains** through `prompt_file`.
- **Posting and conversing in one room.** See [Channels](/channels/).
- **Memory in files** every thread shares. See [Files and memory](/concepts/files-and-memory/).
- **Nothing to approve** until you give it a tool that acts. See
  [Content from outside](/concepts/outside-content/).

## Details

### Answering everything

**Answer every message**, under the app's message, makes it answer without a mention.

### Taking it further

- Add `deep_research` to its tools for a deeper Friday review. See
  [Delegate to other agents](/build/delegation/).
- Keep a battlecard per competitor in a [shared tree](/concepts/files-and-memory/#sharing-trees) for
  sales.
