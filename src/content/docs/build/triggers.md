---
title: Trigger an agent
description: Send an agent a message on a schedule, when a feed has new entries, or when a service sends a webhook.
sidebar:
  order: 5
---

Start agent tasks on a schedule, when an RSS or Atom feed changes, or when a webhook arrives.
Define triggers in the agent file:

```yaml title="~/.config/wardrik/agents/triage.md"
---
tools: [linear/*]
triggers:
  - name: sweep
    every: 30m
    prompt: Check the incident queue, and say what is new.
  - name: digest
    every: "0 17 * * 1-5"
    timezone: Europe/Berlin
    prompt: Write up what happened today.
---
You watch the incident queue.
```

```sh
wardrik reload
wardrik trigger ls triage
```

```text
TRIGGER  RUNS                  NEXT       ASKS
digest   every 0 17 * * 1-5    in 3h 12m  Write up what happened today.
sweep    every 30m             in 29m     Check the incident queue, and say what is new.
```

Trigger messages are added to the agent’s conversation history. See all settings in
[Agent files](/reference/agent-files/#triggers).

## On a schedule

```yaml
every: "*/15 * * * *"    # cron, quoted; UTC unless timezone is set
every: "@daily"          # also @hourly, @weekly, @monthly, @yearly
every: 2h                # an interval: s, m, h or d, at least a minute
```

- A run is skipped if the agent is busy, and missed runs run once on startup. `overlap`, `missed`
  and `jitter` change that. See [triggers](/reference/agent-files/#triggers).
- By default, if the previous turn is still waiting for approval, the next scheduled run
  cancels it and starts a new turn. Set `overlap: skip` to preserve the pending turn.

## When a feed has new entries

```yaml
triggers:
  - name: news
    every: 6h
    feed:
      - https://github.blog/changelog/feed/
      - https://hnrss.org/newest?q=postgres
    prompt: Summarise each new entry in one line in NOTES.md.
```

- When a feed has new entries, Wardrik appends them to the prompt and sends a message to the agent.
- A run with no new entries makes no model call.
- The first run records the current entries and sends nothing.

## When a service sends a webhook

```yaml
triggers:
  - name: issues
    webhook:
      secret: ${ISSUES_HOOK_SECRET}
    prompt: An event is below. If it is a new issue, label it and say who should look.
```

```sh
echo "$SECRET" | wardrik vault put ISSUES_HOOK_SECRET --org acme --for signing_secret
```

The service posts to `{base_url}/v1/hooks/{agent}/{trigger}`:

```text
https://agents.acme.example/v1/hooks/agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN/issues
```

- The request authenticates with the secret, as `Authorization: Bearer SECRET` or as the last path
  segment, `.../issues/SECRET`.
- `verify: standard` checks a [Standard Webhooks](https://www.standardwebhooks.com/) signature
  instead.
- The secret belongs to the agent's owner, stored `--for signing_secret`.
- A request that fails verification returns `404`. The daemon must be reachable at `base_url`. See
  [Public HTTPS access](/run/public-address/).
- Each request costs a model call. Subscribe only to the events you need.

## Change triggers

```sh
wardrik trigger set triage digest --every "0 17 * * 1-5" --prompt "Write up what happened today."
wardrik trigger rm triage digest
```

Over HTTP:

```sh
curl -X PUT -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/$AGENT/triggers/digest \
  -d '{"every": "0 17 * * 1-5", "prompt": "Write up what happened today."}'
```

- `wardrik reload` sets a file-defined agent's triggers to those in the file, and removes the rest.
- With `self/*` in its tools, an agent can set its own triggers. Each change needs approval.
- `prompt_file: HEARTBEAT.md` reads the prompt from the agent's [files](/concepts/files-and-memory/),
  so the agent can edit it.
- `notify: {to: [ops], on: [finished]}` sends each run's reply to a target. See
  [Send notifications](/build/notices/).

## Details

- Feed entries and webhook bodies are [untrusted content](/concepts/outside-content/).
- A webhook with a repeated ID returns `202` and sends one message.
- If the agent can't accept the webhook, it returns `503`, so the service retries.
- The agent receives the first 32,768 characters of a body.
- Each trigger's next run is stored, so triggers survive a restart.
