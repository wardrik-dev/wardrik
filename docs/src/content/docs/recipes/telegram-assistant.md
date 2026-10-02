---
title: An assistant in Telegram
description: A personal assistant you message from your phone, with a persona and memory it keeps in files, a heartbeat it sets itself, and Approve and Deny buttons for what it may not do alone.
sidebar:
  order: 2
---

An assistant you talk to in Telegram. It keeps who it is, who you are and what it has learned in
files of its own, wakes every half hour to follow a checklist it keeps, and writes to you first when
something needs you. A change to its persona, and a day's spending past its allowance, come to you
as a message with Approve and Deny.

The daemon opens no port for any of it. A small bridge, `examples/telegram.ts` in the SDK, asks
Telegram for your messages and dials the daemon's HTTP API on loopback.

## What it takes

- the daemon, [installed](/getting-started/install/) and running, with a model provider's key as the
  [Quickstart](/getting-started/quickstart/#set-it-up) gives it one, and a key for
  `web_search`;
- Node 22.18 or later, for the bridge;
- a Telegram bot. Message [@BotFather](https://t.me/BotFather), send `/newbot`, and keep the token
  it gives you.

## The agent

```markdown title="~/.config/wardrik/agents/assistant.md"
---
description: A personal assistant, in Telegram.
model: anthropic:claude-sonnet-5
user: jon
tools: [files, web_search, run_lua, workers/*]
context: [SOUL.md, USER.md, MEMORY.md]
schedule:
  name: heartbeat
  every: 30m
  prompt_file: HEARTBEAT.md
policy:
  allow_after_outside: [workers/message_me]
  ask:
    write_file(SOUL.md): This changes who I am.
    edit_file(SOUL.md): This changes who I am.
  budget: {usd: 2.00, per: day, on_exhausted: ask}
---
You are a personal assistant to one person, who talks to you in Telegram.

SOUL.md is who you are, USER.md is who they are, and MEMORY.md is what you have learned. Keep
USER.md and MEMORY.md current: what they would want you to know next week belongs there, not only
in this conversation. Keep notes for a day in notes/, by date, and reminders in reminders.md.

Your answers to what they send reach them. Anything you have to tell them in a turn they did not
start, such as a heartbeat, send with message_me, and only what is worth interrupting them for.
run_lua's os.date tells you the time.
```

`user: jon` makes it jon's agent, `default/@jon/assistant`. Read the agent files again:

```sh
wardrik reload
wardrik ls @jon
```

## The bridge

The bridge's token reaches jon's agents and nothing else, and can read, message, decide and offer
tools, but not define agents:

```sh
wardrik token create telegram --scope default/@jon/ --can read,message,decide,serve
```

Send your bot any message, then find your chat's id, the `chat.id` of the message Telegram holds:

```sh
curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates"
```

Run the bridge from a copy of the repository:

```sh
git clone https://github.com/wardrik-dev/wardrik
cd wardrik/sdks/typescript
npm ci
WARDRIK_TOKEN=wardrik_... TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... node examples/telegram.ts
```

It answers your chat alone, and leaves every other one unanswered.

## First words

Tell it who it is, and approve the change to `SOUL.md` when Telegram asks:

> You are Marlow. You are dry, brief, and you never pad an answer. Write that in SOUL.md.

Then who you are, and what to do on each heartbeat:

> I'm Jon, in London. I run a small software company. Keep that in USER.md.
>
> Write a HEARTBEAT.md: check reminders.md and message me about any reminder that is due, then
> remove it. Say nothing between 22:00 and 07:00 my time.

Now `remind me at four to call the bank` puts a line in `reminders.md`, and the first heartbeat
after four messages you about it. The agent can change `HEARTBEAT.md` whenever you ask it to, or
when it sees a reason to, so what it checks grows with what you hand it.

`/stop` stops whatever it is doing.

## How the bridge works

It holds three things open at once:

- **Your messages.** It long-polls Telegram's `getUpdates` and sends what you write with
  `agent.send`, under an id it keeps, so it knows which turns answer you.
- **The agent's events.** It follows `agent.events()`. A `message.completed` in a turn that answers
  you goes back to the chat. A `run.interrupted`, from any turn, goes with the arguments of the call
  it waits on, which the `message.completed` before it named, and Approve and Deny buttons; pressing
  one calls `agent.approve` or `agent.reject`.
- **A tool.** It offers `message_me`, as a [tool worker](/guides/tool-workers/), so a turn you did
  not start can still reach you. The agent has it because its file lists `workers/*`. A worker's
  tool that is not read-only is gated, so it asks unless the policy allows it by name; and once the
  agent has searched the web, what it read stays in its conversation, and an `allow` rule stops
  counting for gated tools in every turn after. `allow_after_outside` allows `message_me` and keeps
  allowing it, since it reaches no one but you.

A heartbeat's own answer goes nowhere: it is in the agent's history, and `wardrik history
@jon/assistant` shows it.

## What it shows

- **Files as memory.** `context` reads `SOUL.md`, `USER.md` and `MEMORY.md` into every turn, and
  the agent sees the names of its other files, which cost only their names until it reads them.
  The files are in the store, so they live wherever the agent does. See
  [Files and memory](/concepts/files-and-memory/).
- **A heartbeat it edits.** `prompt_file` asks it to follow `HEARTBEAT.md` as it stands each time.
  See [A checklist the agent can edit](/guides/schedules/#a-checklist-the-agent-can-edit).
- **Rules outside the conversation.** The policy is not in the prompt, so no instruction to the
  agent loosens it, and no summary of a long history loses it: a change to `SOUL.md` asks you
  every time. See [Policy and approvals](/concepts/policy/).
- **One tool allowed after the web.** An agent that reads what strangers wrote, knows about you,
  and can change things needs a person for the last of those. `message_me` only reaches you, so
  `allow_after_outside` lets it through; any gated tool you add later still asks. See
  [Allowing after content from outside](/concepts/policy/#allowing-after-content-from-outside).
- **An allowance.** Past two dollars in a day, its next model call waits on you, with "This agent
  has spent $2.01 of $2.00 today. Approve to allow $2.00 more." See
  [Budgets](/concepts/policy/#budgets).
- **A token for one job.** The bridge cannot reach another user's agents or define new ones, and
  revoking its token closes its streams and its worker's connection. See
  [Tokens](/operate/security/#tokens).

## Taking it further

- Give it the tools of your calendar's or your mail's MCP server, and add to `HEARTBEAT.md` what to
  look for in them. Mail is anyone's to write, so gate the tools that send: see
  [Let anyone try to hijack it](/recipes/hijack-me/) for why that holds.
- Run the bridge under systemd beside the daemon, or anywhere that reaches the daemon's port.
- Give everyone in a family or a team an agent of their own, each with `user:` set and a bridge
  whose token reaches only theirs.
