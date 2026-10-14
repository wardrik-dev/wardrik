---
title: Trigger an agent
description: Ask an agent something on a clock, when a feed has something new, or when a service sends a webhook.
sidebar:
  order: 5
---

A trigger asks an agent something without anyone typing: on a clock, when a feed it watches has new
entries, or when a service sends it a webhook. Triggers live in the agent's file:

```yaml title="~/.config/wardrik/agents/triage.md"
---
tools: [linear/*]
triggers:
  - name: sweep
    every: 30m
    prompt: Check the incident queue, and say what is new.
  - name: digest
    every: "0 17 * * 1-5"
    prompt: Write up what happened today.
---
You watch the incident queue.
```

```sh
wardrik reload
wardrik triggers
```

```text
2 triggers:
  default/triage/digest  0 17 * * 1-5  next in 3h 12m  not run yet
  default/triage/sweep  every 30m  next in 29m  not run yet
```

A triggered run is an ordinary message to the agent: it shows in its history, and `wardrik watch`
follows it. Every key a trigger takes is in [Agent files](/reference/agent-files/#triggers).

## On a clock

`every` is a cron expression or an interval.

```yaml
every: "*/15 * * * *"    # every quarter of an hour, in UTC
every: "0 9 * * 1"       # nine on Monday mornings
every: "@daily"          # also @hourly, @weekly, @monthly and @yearly
every: 2h                # an interval: s, m, h or d, at least a minute
```

Quote a cron expression: YAML reads a leading `*` as something else. An interval counts from when
the trigger was set or last ran, so `1d` set at 14:20 runs at 14:20. A new trigger first runs when
it next comes round.

By default a run skips an agent that is busy, and `wardrik triggers` says so. `overlap: queue` asks
it anyway, once the running turn ends or the waiting call is decided.

## Watching a feed

`feed` watches an RSS or Atom feed, or a list of them. The agent is asked only when a feed has
entries it hasn't seen, with them under the prompt:

```yaml
triggers:
  - name: rivals
    every: 6h
    feed:
      - https://rivalco.example/changelog.rss
      - https://hnrss.org/newest?q=rivalco
    prompt: What changed at our competitors? Update shared/team/BATTLECARDS.md.
```

A run with nothing new costs a request to each feed and no model call. The first run only notes
what the feed already holds, so the agent starts with what comes next.

Many places a team watches have a feed:

| What | Its feed |
| --- | --- |
| A Google Alert | in [Google Alerts](https://www.google.com/alerts), choose **Deliver to: RSS feed** |
| Hacker News stories mentioning a word | `https://hnrss.org/newest?q=WORD` |
| A subreddit, or a Reddit search | `https://www.reddit.com/r/NAME/.rss`, `https://www.reddit.com/search.rss?q=WORD` |
| A GitHub repository's releases | `https://github.com/OWNER/REPO/releases.atom` |
| A blog or changelog | the `rss` or `atom` link in its page's `<head>`, often `/feed` or `/rss.xml` |

## Receiving a webhook

`webhook` takes the requests a service sends when something happens, such as an issue opened, and
asks the agent about each, with the request's body under the prompt. It has no `every`:

```yaml
triggers:
  - name: issues
    webhook:
      secret: ${ISSUES_HOOK_SECRET}
    prompt: An event is below. If it is a new issue, label it and say who should look.
```

The service sends to the trigger's address under `config.yaml`'s `base_url`, which
`wardrik triggers` prints:

```text
https://agents.acme.example/v1/hooks/acme/triage/issues
```

The request proves itself with the secret: as `Authorization: Bearer SECRET`, or at the end of the
path, `.../issues/SECRET`, for a service that only takes a URL. A request that doesn't verify gets
`404` and never reaches the agent. The daemon must be reachable at `base_url`; see
[A public address](/run/public-address/).

### Pointing a service at a trigger

| Service | Where you set it up | The secret |
| --- | --- | --- |
| GitHub | the repository's **Settings → Webhooks**, content type `application/json` | end of the path |
| Sentry | an internal integration's **Webhook URL**, with **Alert Rule Action** on, and an issue alert that sends through it | end of the path |
| Linear | **Settings → API → New webhook** | end of the path |
| Prometheus Alertmanager | a receiver's `webhook_configs`, with `http_config.authorization` | bearer |
| Grafana | a webhook contact point's **Authorization header** | bearer |
| PagerDuty | a webhook subscription, with a custom `Authorization` header | bearer |
| A service following [Standard Webhooks](https://www.standardwebhooks.com/) | its webhook settings, with `verify: standard` | its signature |
| An automation tool | its webhook or HTTP step | bearer |

A secret at the end of the path is what proves the request, so keep that URL as private as a token.
Each request costs a model call: subscribe to the events that matter, and let the prompt pass over
the rest in a line.

```yaml title="alertmanager.yml"
receivers:
  - name: wardrik
    webhook_configs:
      - url: https://agents.acme.example/v1/hooks/acme/oncall/alert
        http_config:
          authorization:
            type: Bearer
            credentials: SECRET
```

## A checklist the agent can edit

`prompt_file` points a trigger at a file in the agent's workspace instead of a prompt. Each run, the
agent reads the file and does what it says, and it can edit the file to change what it does next
time. It needs `files`:

```yaml
tools: [files, linear/*]
triggers:
  - name: heartbeat
    every: 30m
    prompt_file: HEARTBEAT.md
```

See [Files and memory](/concepts/files-and-memory/).

## An agent that changes its own triggers

`self/*` lets an agent set and remove its own triggers: add a feed it found, check more often after
a launch, drop a check that never finds anything. Each change waits on a person unless its policy
allows it.

```yaml
tools: [web_search, files, self/*]
```

This works for agents defined over the HTTP API. An agent declared in a file keeps the triggers its
file lists.

## Hearing what it did

`notify` with `finished` sends each run's answer somewhere people read it:

```yaml
notify: {to: [ops], on: [parked, failed, finished]}
```

See [Send notices](/build/notices/).

## Changing and removing triggers

`wardrik reload` gives each agent the triggers its file lists now and removes the rest. A changed
`every` starts counting from the reload; other changes keep the next run where it was.

## Over HTTP

A definition sent over the HTTP API lists its triggers as a file does. With a token that can
`define`, set or remove one at a time:

```sh
curl -X PUT -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage/triggers/digest \
  -d '{"every": "0 17 * * 1-5", "prompt": "Write up what happened today."}'

curl -X DELETE -H "authorization: Bearer $TOKEN" \
  http://127.0.0.1:4747/v1/agents/acme/triage/triggers/digest
```

See [HTTP API](/reference/http-api/#triggers) for the routes and their answers.

## Details

**Clock.** Cron has five fields, in UTC: minute, hour, day of the month, month, day of the week (0
and 7 are Sunday). Fields take `*`, numbers, ranges like `1-5`, steps like `*/15`, and lists; names
like `MON` aren't read. Where both day fields are given, a day matching either runs. `jitter: 120`
adds up to that many seconds to each run, so triggers on the same minute don't all fire at once.

**Busy agents.** With `overlap: queue`, a running turn stops at its next step and the triggered
message is answered in the turn after. A webhook trigger queues by default; with `overlap: skip` it
answers `503` while the agent is busy.

**Missed runs.** A run more than a minute late, because the daemon was down, runs once when the
trigger next runs, however many were missed. `missed: skip` drops them.

**Feeds.** A message carries up to 20 entries, each with its title, link, date and summary; more
are counted at the end. A feed that hasn't changed answers with nothing. A feed that can't be read
is tried again next run; the run fails only when none can be read.

**Webhook secrets.** `secret` names a secret as `${NAME}`, read for the agent as a tool's credential
is; see [Whose credential](/build/accounts/#whose-credential). `wardrik vault put
ISSUES_HOOK_SECRET --org acme` gives each org its own. The address names the agent by its ID, as
`/v1/agents/` does, so it reaches only that agent's triggers. Services' own signatures, such as
GitHub's or Sentry's, aren't checked; leave GitHub's secret field empty or set, as you like.

**Webhook delivery.** `verify: standard` checks a Standard Webhooks signature, which covers the body
and a time, so a copied request soon stops verifying. A host embedding Wardrik can register its own
verifier. A request's ID is its `Idempotency-Key`, its `webhook-id` when signed, or else its body's
hash; the trigger remembers the last 500 and answers a repeat `202` without asking again. A request
it can't deliver now, such as to an agent that isn't running, gets `503`, so the service retries
later. The agent sees the body's first 32,768 characters. A request that fails to verify is logged
with why.

**Content from outside.** Feed entries and webhook bodies are written by others, so once the agent
reads them a gated tool's calls wait on a person. See
[Content from outside](/concepts/outside-content/).

**Self-set triggers.** The audit records the agent as who set a trigger, and `wardrik triggers`
lists it like any other.

**Cluster.** A trigger runs once in the cluster, on the node that holds it. Its next run is written
to the store before the agent is asked, so a lost node's triggers carry on from another.

**Seeing triggers.** `wardrik status` and `wardrik ls` show when each agent next runs; `wardrik show`
lists its triggers.

**Over HTTP.** Putting a whole definition again gives the agent the triggers it lists then. The body
of a single-trigger `PUT` is the trigger without its `name`, which comes from the path.
`GET .../definition` lists the triggers as they stand. An agent with no definition kept answers
`404`, and a file-declared agent's triggers can't be changed over HTTP (`409`). Removing `triggers`
from a file removes all of that agent's triggers.
