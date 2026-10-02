---
title: A morning brief
description: An agent that reads up on what you follow, and on what waits for you on GitHub, and posts a short brief to Slack each weekday morning.
sidebar:
  order: 1
---

Each weekday morning this agent searches for what changed in the things you follow, looks at what
waits for you on GitHub, and posts a brief of it to a Slack channel. It is one agent file and a few
lines of `config.yaml`, and the quickest of these recipes to have running.

## What it takes

- the daemon, [installed](/getting-started/install/) and running, with a model provider's key as the
  [Quickstart](/getting-started/quickstart/#set-it-up) gives it one;
- a key for `web_search`, where the daemon reads its keys. A search made without one tells the
  agent which key it lacks;
- a Slack app with a bot token, made as [Approve calls from Slack](/guides/slack/#a-slack-app) makes
  one. This recipe only posts, so it needs no app-level token;
- for the GitHub part, a personal access token that can read your repositories.

`SLACK_BOT_TOKEN` and `GITHUB_TOKEN` are read where `config.yaml` reads any `${NAME}`, as
[Connect MCP servers](/guides/mcp/) says.

## Where it posts

Name the channel in `config.yaml`, and GitHub's MCP server beside it:

```yaml title="~/.config/wardrik/config.yaml"
notify:
  brief:
    slack:
      channel: "#brief"
      token: ${SLACK_BOT_TOKEN}

mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    headers:
      authorization: Bearer ${GITHUB_TOKEN}
    only: [get_me, search_issues, search_pull_requests]
```

`only` gives the agent three of GitHub's reading tools and nothing else, so it has no way to change
anything there. Restart the daemon, which reads `config.yaml` as it starts, and check it:

```sh
systemctl --user restart wardrik
wardrik doctor
```

## The agent

```markdown title="~/.config/wardrik/agents/brief.md"
---
description: Posts a brief each weekday morning.
model: anthropic:claude-sonnet-5
tools: [web_search, github/*, files]
context: [FOLLOWING.md]
schedule:
  name: morning
  every: "30 6 * * 1-5"     # 06:30 UTC, Monday to Friday
  prompt: Write this morning's brief.
notify: {to: [brief], on: [finished, failed]}
policy:
  budget: {usd: 1.00, per: day, on_exhausted: deny}
---
You write a short morning brief for one person.

FOLLOWING.md lists what they follow. For each, search for what changed since yesterday, and keep
only what they would be sorry to miss. Then search GitHub for the pull requests that wait on their
review, and the issues assigned to them.

Answer with the brief itself, under 250 words: a line for each thing worth knowing, with a link,
and the pull requests that wait on them last. Say nothing about what you left out.

When they tell you what they follow, or what they want more or less of, keep it in FOLLOWING.md.
```

`context` reads `FOLLOWING.md` into every turn, and `files` lets the agent keep it. Read the agent
files again, and tell it what you follow:

```sh
wardrik reload
wardrik ask brief "I follow Elixir releases, the Postgres mailing lists, and anything new from Fly.io."
wardrik ask brief "Write this morning's brief now."
```

Both answers reach Slack as well, since every turn the agent finishes is sent there; the second is
what each morning brings. `wardrik schedules` says when it runs next.

## What it shows

- **A schedule.** `every` is cron, in UTC, and a run missed while the daemon was down runs once
  when it comes back. See [Run an agent on a schedule](/guides/schedules/).
- **Notices.** `finished` sends what each turn answered to the target, which suits an agent whose
  answers someone reads elsewhere. See [Approve calls from Slack](/guides/slack/).
- **Memory in a file.** What you follow lives in `FOLLOWING.md`, which you can change by telling the
  agent, rather than in its system prompt. See [Files and memory](/concepts/files-and-memory/).
- **A budget.** Once the agent has spent a dollar in a day, `on_exhausted: deny` refuses its next
  model call, which ends the turn, rather than asking. See [Budgets](/concepts/policy/#budgets).

## Taking it further

- Change the cron to your morning: `"0 7 * * 1-5"` is 07:00 UTC.
- Ask it things during the day, `wardrik ask brief "What did the Postgres list decide about..."`:
  it is the same agent, with the same history.
- Give it your issue tracker's MCP server as well, and ask for what is assigned to you.
