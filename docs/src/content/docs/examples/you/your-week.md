---
title: Your week
description: "A chief of staff: a plan each morning, prep for your meetings, and invites that wait for your say-so."
sidebar:
  order: 2
---

Each weekday morning this agent reads your calendar, your inbox and your task list, and posts the
day's plan: what's on, what to prepare, what's overdue. It blocks focus time on your own calendar
and drafts the emails your meetings need. Anything that invites someone else waits for you.

## What it takes

- the Google setup from [Inbox triage](/examples/you/inbox-triage/): the `gmail` and `gcal` servers
  and the `google` provider in `config.yaml`;
- a [Slack app](/channels/slack/#a-slack-app) in a workspace of your own, and a channel for it,
  here `#week`, as a `notify` target named `week`.

## The files

### The policy

```yaml title="~/.config/wardrik/policies/week.yaml"
allow_after:
  outside:
    - gmail/create_draft
    - gcal/create_event
ask:
  gcal/create_event(attendeeEmails = *): This invites other people.
  gcal/update_event: This moves an event.
  gcal/respond_to_event: This answers an invitation.
deny:
  gcal/delete_event: Nothing on a calendar is deleted.
budget:
  usd: 1.00
  per: day
```

- **An event just for you runs.** Focus blocks and reminders need no one's say-so.
- **An event with anyone else on it waits.** The rule names `attendeeEmails`: a call with any
  attendee matches, and a call with none doesn't. An `ask` wins over `allow_after`.
- **Moving or answering invites waits,** since other people see it.

### The agent

```markdown title="~/.config/wardrik/agents/week.md"
---
description: Plans my day each morning and keeps my calendar honest.
tools: [gmail/*, gcal/*, files]
context: [TASKS.md]
policy: week
notify: {to: [week], on: [parked, failed, finished]}
triggers:
  - name: plan
    every: "30 6 * * 1-5"        # 06:30 UTC on weekdays
    prompt: Plan my day.
---
You are my chief of staff. TASKS.md is my task list; keep it current as I tell you things.

Each morning, post the plan: today's meetings with a line of prep for each, the tasks that fit the
gaps, and what's overdue. Block focus time for the two most important tasks. Draft the emails my
meetings need: an agenda, a follow-up, a "running late".

If two meetings clash, propose which to move. Never invite anyone without asking.
```

## Try it

```sh
wardrik reload
wardrik ask week "Add to TASKS.md: send the Q3 numbers to Priya by Thursday."
wardrik ask week "Plan my day."
```

The plan lands in `#week`. Focus blocks appear on your calendar. If it proposes moving a meeting, or
a meeting with someone, the call waits in `#week` with **Approve** and **Deny**.

## What it shows

- **Two kinds of calendar write, told apart by their arguments.** Yours runs; anyone else's waits.
- **A task list it maintains,** read into every turn.
- **A clock trigger** that runs only on weekdays.

## Details

### List arguments

`attendeeEmails` is a list. An `ask` or `deny` with a condition on a list speaks for a call where any
item matches; an `allow` only where every item does. A call that leaves the argument out matches no
condition on it. See [Writing rules](/concepts/rules/#what-a-calls-arguments-are).

### Taking it further

- Let it reply to scheduling emails with drafts that offer times from Calendar's `suggest_time`.
- Run it with [Inbox triage](/examples/you/inbox-triage/): both read the same calendar.
