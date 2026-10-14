---
title: A morning brief
description: An agent that posts what changed in what you follow, and what waits for you on GitHub, to Slack each weekday morning.
sidebar:
  order: 1
---

Each weekday morning it posts what changed in what you follow, and what waits for you on GitHub, to
Slack. It's the quickest example to run.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key from the
  [Quickstart](/getting-started/quickstart/#1-install);
- a key for `web_search`;
- a [Slack app](/channels/slack/#a-slack-app) with a bot token. It only posts, so it needs no
  app-level token;
- a GitHub personal access token that can read your repositories.

`${SLACK_BOT_TOKEN}` and `${GITHUB_TOKEN}` come from the environment or the vault; see
[Connect MCP servers](/build/mcp/).

## The files

### config.yaml

The Slack room it posts to, and GitHub's MCP server:

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}

notify:
  brief:
    channel: slack
    room: "#brief"

mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    headers:
      authorization: Bearer ${GITHUB_TOKEN}
    only: [get_me, search_issues, search_pull_requests]
```

`only` keeps GitHub read-only. Restart and check:

```sh
systemctl --user restart wardrik
wardrik doctor
```

### The agent

```markdown title="~/.config/wardrik/agents/brief.md"
---
description: Posts a brief each weekday morning.
model: anthropic:claude-sonnet-5
tools: [web_search, github/*, files]
context: [FOLLOWING.md]
triggers:
  - name: morning
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

## Try it

Tell it what you follow; it keeps that in `FOLLOWING.md`:

```sh
wardrik reload
wardrik ask brief "I follow Elixir releases, the Postgres mailing lists, and anything new from Fly.io."
wardrik ask brief "Write this morning's brief now."
```

Both answers also reach Slack; the second is what each morning brings. `wardrik triggers` says when
it runs next.

## What it shows

- **A trigger.** Cron in UTC; a run missed while the daemon was down runs once when it's back. See
  [Trigger an agent](/build/triggers/).
- **Notices.** `finished` sends each answer to the room. See [Send notices](/build/notices/).
- **Memory in a file.** What you follow lives in `FOLLOWING.md`, which you change by telling the
  agent. See [Files and memory](/concepts/files-and-memory/).
- **A budget.** After a dollar a day, `on_exhausted: deny` ends the turn instead of asking. See
  [Budgets](/concepts/budgets/).

## Details

### Taking it further

- Change the cron to your morning: `"0 7 * * 1-5"` is 07:00 UTC.
- Ask it things during the day, `wardrik ask brief "What did the Postgres list decide about..."`.
  It's the same agent, with the same history.
- Give it your issue tracker's MCP server as well, and ask for what is assigned to you.
