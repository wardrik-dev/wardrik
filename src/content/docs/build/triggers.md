---
title: Trigger an agent
description: Ask an agent something on a clock, when a feed has something new, or when a service sends a webhook.
sidebar:
  order: 5
---

A trigger asks an agent something without anyone typing. List triggers in the agent's file:

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

A triggered run is an ordinary message. It shows in the agent's history. Every key is in
[Agent files](/reference/agent-files/#triggers).

## On a clock

```yaml
every: "*/15 * * * *"    # cron, quoted; UTC unless timezone names another
every: "@daily"          # also @hourly, @weekly, @monthly, @yearly
every: 2h                # an interval: s, m, h or d, at least a minute
```

- A run skips a busy agent. `overlap: queue` asks once the agent is free.
- Runs missed while the daemon was down run once. `missed: skip` drops them.
- `jitter: 120` adds up to 120 seconds to each run.

## When a feed has something new

```yaml
triggers:
  - name: rivals
    every: 6h
    feed:
      - https://github.com/elixir-lang/elixir/releases.atom
      - https://hnrss.org/newest?q=elixir
    prompt: What's new in Elixir? Keep a line on each in NOTES.md.
```

- The agent is asked only when a feed has new entries, with them under the prompt.
- A run with nothing new makes no model call.
- The first run notes what the feed holds, and asks nothing.

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

- The request proves itself with the secret: as `Authorization: Bearer SECRET`, or at the end of
  the path, `.../issues/SECRET`.
- `verify: standard` checks a [Standard Webhooks](https://www.standardwebhooks.com/) signature
  instead.
- The secret is the agent owner's, sealed `--for signing_secret`.
- A request that doesn't verify gets `404`. The daemon must be reachable at `base_url`: see
  [A public address](/run/public-address/).
- Each request costs a model call. Subscribe to the events that matter.

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

- `wardrik reload` gives a file's agent the triggers its file lists, and removes the rest.
- `self/*` in an agent's tools lets it set its own triggers. Each change waits on a person.
- `prompt_file: HEARTBEAT.md` reads the prompt from the agent's [files](/concepts/files-and-memory/),
  which it can edit.
- `notify: {to: [ops], on: [finished]}` sends each run's answer somewhere. See
  [Send notices](/build/notices/).

## Details

- Feed entries and webhook bodies are [content from outside](/concepts/outside-content/).
- A webhook repeated with the same ID is answered `202` and asked once.
- A webhook the agent can't take now gets `503`, so the service retries.
- The agent sees a body's first 32,768 characters.
- A trigger's next run is in the store, so triggers carry on after a restart.
