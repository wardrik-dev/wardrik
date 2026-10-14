---
title: An assistant in Telegram
description: A personal assistant on your phone, with memory in files, a heartbeat it edits, and Approve and Deny buttons.
sidebar:
  order: 2
---

A personal assistant in Telegram. It remembers in files, wakes every half hour to follow its own
checklist, and messages you first when something needs you. A small SDK bridge connects Telegram to
the daemon, which opens no port.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key from the
  [Quickstart](/getting-started/quickstart/#1-install), and a key for `web_search`;
- Node 22.18 or later, for the bridge;
- a Telegram bot: message [@BotFather](https://t.me/BotFather), send `/newbot`, and keep the token.

## The agent

```markdown title="~/.config/wardrik/agents/assistant.md"
---
description: A personal assistant, in Telegram.
model: anthropic:claude-sonnet-5
user: jon
tools: [files, web_search, run_lua, workers/*]
context: [SOUL.md, USER.md, MEMORY.md]
triggers:
  - name: heartbeat
    every: 30m
    prompt_file: HEARTBEAT.md
policy:
  allow_after:
    outside: [workers/message_me]
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

`user: jon` makes it jon's agent, `default/@jon/assistant`. Load it:

```sh
wardrik reload
wardrik ls @jon
```

## Try it

Make the bridge a token that reaches only jon's agents and can't define new ones:

```sh
wardrik token create telegram --scope default/@jon/ --can read,message,decide,serve
```

Send your bot any message, then find your chat's `chat.id`:

```sh
curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates"
```

Run the bridge from a copy of the repository. It answers your chat alone:

```sh
git clone https://github.com/wardrik-dev/wardrik
cd wardrik/sdks/typescript
npm ci
WARDRIK_TOKEN=wardrik_... TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... node examples/telegram.ts
```

Tell it who it is, and approve the change to `SOUL.md` when Telegram asks:

> You are Marlow. You are dry, brief, and you never pad an answer. Write that in SOUL.md.

Then who you are, and what to do on each heartbeat:

> I'm Jon, in London. I run a small software company. Keep that in USER.md.
>
> Write a HEARTBEAT.md: check reminders.md and message me about any reminder that is due, then
> remove it. Say nothing between 22:00 and 07:00 my time.

Now `remind me at four to call the bank` adds a line to `reminders.md`, and the heartbeat after four
messages you. `/stop` stops whatever it's doing.

## What it shows

- **Files as memory**, read into every turn. See [Files and memory](/concepts/files-and-memory/).
- **A heartbeat it edits.** See
  [A checklist the agent can edit](/build/triggers/#a-checklist-the-agent-can-edit).
- **Rules outside the conversation.** Changing `SOUL.md` asks you every time. See
  [Policy](/concepts/policy/).
- **One tool allowed after the web.** `message_me` reaches only you, so `allow_after` lets it run.
  See [Content from outside](/concepts/outside-content/#allowing-after-content-from-outside).
- **An allowance.** Past $2 a day, it asks. See [Budgets](/concepts/budgets/).
- **A token for one job.** See [Tokens](/run/tokens/).

## Details

### How the bridge works

- **Your messages:** it long-polls Telegram and sends each with `agent.send`.
- **The agent's events:** answers to you go to the chat; a `run.interrupted` arrives with the call's
  arguments and Approve and Deny buttons.
- **A tool:** it offers `message_me` as a [tool worker](/build/tool-workers/), so a heartbeat can
  reach you.

A heartbeat's own answer stays in the agent's history: `wardrik history @jon/assistant`. Revoking
the bridge's token closes its connections.

### Taking it further

- Add your calendar's or mail's MCP server. Mail is anyone's to write, so gate the tools that send;
  see [Let anyone try to hijack it](/examples/hijack-me/).
- Run the bridge under systemd beside the daemon.
- Give each person their own agent (`user:`) and a bridge token that reaches only theirs.
