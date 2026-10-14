---
title: Trigger an agent
description: Ask an agent something on a clock, with cron or an interval, when a feed it watches has something new, or when a service sends it a webhook, and give it a checklist it can edit.
sidebar:
  order: 5
---

A trigger asks an agent something when it comes round, here on a clock; it can also watch a feed,
or take a service's webhooks. An agent's triggers are part of its definition, here its agent file:

```yaml title="~/.config/wardrik/agents/triage.md"
---
model: anthropic:claude-sonnet-5
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

Read the agent files again, and see when each trigger runs:

```sh
wardrik reload
wardrik triggers
```

```
2 triggers:
  default/triage/digest  0 17 * * 1-5  next in 3h 12m  not run yet
  default/triage/sweep  every 30m  next in 29m  not run yet
```

`wardrik status` and `wardrik ls` show when each agent next runs, and `wardrik show` lists its
triggers.

A triggered run is an ordinary message to the agent. It is in the agent's history like any other,
and `wardrik watch` follows it.

## When it runs

`every` is a cron expression or an interval.

**Cron** takes five fields, in UTC: minute, hour, day of the month, month, and day of the week,
where 0 and 7 are Sunday. Each field takes `*`, a number, a range such as `1-5`, a step such as
`*/15`, or a list of them. Quote it, since YAML reads a leading `*` as something else.

```yaml
every: "*/15 * * * *"    # every quarter of an hour
every: "0 9 * * 1"       # nine on Monday mornings
every: "0 0 1 * *"       # midnight on the first of the month
every: "@daily"          # also @hourly, @weekly, @monthly and @yearly
```

Fields take numbers only: `MON` and `JAN` are not read. Where both the day of the month and the day
of the week are given, a day matching either runs.

**An interval** is a number and a unit, `s`, `m`, `h` or `d`, of at least a minute: `30m`, `2h`,
`1d`. It is measured from when the trigger was set or last ran, not from the top of the hour, so
`1d` set at 14:20 runs at 14:20.

`jitter` adds up to that many seconds to each run, so several triggers on the same minute do not
all ask at once:

```yaml
every: "0 * * * *"
jitter: 120
```

A new trigger runs first when it next comes round, not as soon as it is set.

## When the agent is busy

By default a run that finds the agent running a turn, or waiting on a person, lets it be, and
`wardrik triggers` says the run was skipped. `overlap: queue` asks it anyway:

- a running turn stops at its next step, and the triggered message is answered in the turn after,
  with what the running one left;
- an agent waiting on a person answers it once what it waits on is decided.

```yaml
overlap: queue
```

## When the daemon was down

A run more than a minute late, because the daemon was stopped or every node was lost, runs once when
the trigger is next running, however many runs were missed. `missed: skip` lets them go instead:

```yaml
missed: skip
```

## Watching a feed

`feed` makes a trigger watch an RSS or Atom feed, or a list of them. On each run the feeds are read,
and the agent is asked only when one has entries it has not seen, with each entry's title, link,
date and summary under the prompt:

```yaml
triggers:
  - name: mentions
    every: 1h
    feed: https://www.google.com/alerts/feeds/0123456789/0123456789
    prompt: New mentions of Acme. Say which deserve a reply, and draft it.
  - name: rivals
    every: 6h
    feed:
      - https://rivalco.example/changelog.rss
      - https://hnrss.org/newest?q=rivalco
    prompt: What changed at our competitors? Update shared/team/BATTLECARDS.md.
```

- **A run with nothing new asks nothing.** It costs a request to each feed, and no model call;
  `wardrik triggers` says it found nothing new. A feed that has not changed since the last run
  answers with nothing at all.
- **The first run only reads.** What a feed already holds is noted as seen, so a new trigger
  starts with what comes next rather than the feed's whole history.
- **Up to 20 entries a message.** More than that are counted at the end of the message.
- **Entries are content from outside.** Whoever wrote them could be asking for the agent's next
  call, so a gated tool's calls wait on a person once the agent has read them. See
  [Content from outside](/concepts/policy/#content-from-outside).
- **A feed that cannot be read is tried again on the next run**, and the others are read as usual.
  The run fails only when none can be read.

Many places a team watches have a feed:

| What | Its feed |
| --- | --- |
| A Google Alert | in [Google Alerts](https://www.google.com/alerts), under the alert's options, choose **Deliver to: RSS feed** |
| Hacker News stories that mention a word | `https://hnrss.org/newest?q=WORD` |
| A subreddit, or a search of Reddit | `https://www.reddit.com/r/NAME/.rss`, `https://www.reddit.com/search.rss?q=WORD` |
| A GitHub repository's releases | `https://github.com/OWNER/REPO/releases.atom` |
| A blog or changelog | the `rss` or `atom` link in its page's `<head>`, often `/feed`, `/rss.xml` or `/atom.xml` |

## Receiving a webhook

`webhook` makes a trigger take the requests a service sends when something happens there, such as
an issue opened or a payment made, and ask the agent about each. It has no `every`: it asks as each
request arrives, with the request's body under the prompt. Its own settings go under `webhook`:

```yaml
triggers:
  - name: issues
    webhook:
      secret: ${ISSUES_HOOK_SECRET}
    prompt: An event is below. If it is a new issue, label it and say who should look.
```

A service sends its requests to the trigger's path, which names the agent by its ID, as
`/v1/agents/` does, and the trigger by its name, under the deployment's address, `config.yaml`'s
`base_url`:

```
https://agents.acme.example/v1/hooks/acme/triage/issues
https://agents.acme.example/v1/hooks/acme/@jon/triage/issues
```

`wardrik triggers` prints each webhook's address. The path reaches that agent's triggers and
nothing else: a request to it can only ask that agent, through that trigger.

- **The request presents the secret.** `secret` names the secret you give the service, as
  `${NAME}`, read as a tool's credential is: the vault's for the agent's user, then its org, then
  the deployment, then the environment. `wardrik vault put ISSUES_HOOK_SECRET --org acme` seals one
  for an org, so each org's agents check with their own. A service that sets headers sends
  `Authorization: Bearer` and the secret; one that lets you set only a URL puts the secret at the
  end of the path, as `.../issues/SECRET`.
- **A service that signs, by the [Standard Webhooks](https://www.standardwebhooks.com/) spec,** is
  checked by its signature instead, with `verify: standard` under `webhook`. The signature covers
  the body and a time, so a request someone copied does not verify for long. A host that embeds
  Wardrik can register a verifier of its own for any other signature, and name it the same way.
- **A request that does not verify is answered `404`,** as one to a trigger that does not exist,
  so a request tells its sender nothing of triggers it holds no secret for; the daemon's log says
  why. The agent is not asked.
- **A request sent again is asked about once.** Services send a request again when they hear
  nothing back in time. A request's ID is its `Idempotency-Key`, or for a signed one its
  `webhook-id`, and otherwise the hash of its body. The trigger keeps the last 500 it asked about,
  and answers a repeat `202` without asking again.
- **A request that cannot be delivered now is answered `503`**, such as one to an agent that is
  not running, and the trigger does not keep it, so a service that tries again delivers it later.
  A webhook trigger queues behind a running turn unless it says `overlap: skip`, which answers
  `503` while the agent is busy.
- **The body is content from outside.** Whoever made the event could be asking for the agent's
  next call, so a gated tool's calls wait on a person once the agent has read it. The agent is
  shown the body's first 32,768 characters.
- **The service must reach the daemon.** It listens on `127.0.0.1` unless `config.yaml`'s `http`
  says otherwise; put it behind a proxy that serves HTTPS, or a tunnel, at `base_url`.

### Pointing a service at a trigger

Any service that can send a webhook to a URL can reach a trigger. What differs is where you give it
the secret: a service that sets headers sends `Authorization: Bearer` and the secret; one that lets
you set only a URL gets the secret at the end of the trigger's path. A service's own signature,
such as GitHub's or Sentry's, is not checked, so the secret in the path is what proves a request:
keep that URL as private as a token.

| Service | Where you set it up | The secret | For example |
| --- | --- | --- | --- |
| GitHub | the repository's or organization's **Settings → Webhooks** | end of the path | an issue opened, a pull request, a failed workflow run |
| Sentry | an internal integration's **Webhook URL**, which an issue alert sends to | end of the path | a new issue |
| Linear | **Settings → API → New webhook** | end of the path | an issue created |
| Prometheus Alertmanager | a receiver's `webhook_configs`, with `http_config.authorization` | bearer | an alert firing |
| Grafana | a webhook contact point's **Authorization header** | bearer | an alert firing |
| PagerDuty | a webhook subscription, with a custom header named `Authorization` | bearer | an incident triggered |
| A service that follows Standard Webhooks | its webhook settings, with `verify: standard` | its signature | whatever it sends |
| An automation tool | its webhook or HTTP request step | bearer | anything it connects |

Each request is a model call, so ask a service for the events the agent should hear, and let the
prompt pass over the rest in a line.

**Triage each new GitHub issue.** In the repository's **Settings → Webhooks**, add a webhook whose
payload URL is the trigger's address with the secret after it, with content type
`application/json`, and choose **Issues** among the individual events:

```yaml
triggers:
  - name: issue-opened
    webhook:
      secret: ${GITHUB_HOOK_SECRET}
    prompt: >
      A GitHub issue event is below. If it opened an issue, label it, link the issues it may
      duplicate, and say who should look. Otherwise answer in one line.
```

```
https://agents.acme.example/v1/hooks/acme/triage/issue-opened/SECRET
```

GitHub sends an event for each change to an issue, opened, edited, closed and more, so the prompt
says which matter. GitHub's own secret field signs what it sends, which the trigger does not
check; leave it empty or set, as you like.

**Look into each new Sentry issue.** In Sentry, create an internal integration under
**Settings → Developer Settings → Custom Integrations**, with the trigger's address and its secret
as the webhook URL, and **Alert Rule Action** on. Then add an issue alert to the project: when a
new issue is created, send a notification through that integration:

```yaml
triggers:
  - name: sentry-issue
    webhook:
      secret: ${SENTRY_HOOK_SECRET}
    prompt: >
      Sentry found a new issue; its alert is below. Read the stack trace, find the code and the
      commits around it, and say what most likely broke and who changed it last.
```

**Hear an alert as it fires.** Alertmanager sends the secret as a bearer token:

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

`prompt_file` asks the agent to follow a file in its workspace, in place of `prompt`. Each run it
is asked:

> It is time for `heartbeat`. Read `HEARTBEAT.md` with read_file, and do what it says as it stands
> now. If it asks nothing of you, answer in one line.

The agent can edit the file, so it can change what it does next time: add a check, drop one that is
done, or note when to look again. It needs `files` in its tools:

```yaml
tools: [files, linear/*]
context: [MEMORY.md]
triggers:
  - name: heartbeat
    every: 30m
    prompt_file: HEARTBEAT.md
```

The file is read as the run happens, so one that does not exist yet is the agent's to find out
about. See [Files and memory](/concepts/files-and-memory/).

## An agent that changes what it watches

`self/*` in an agent's tools lets it read its own definition, and set and remove its own triggers,
so it can change what it watches as it learns what matters: add a feed it found, check a page more
often after a launch, or drop a check that never finds anything.

```yaml
tools: [web_search, files, self/*]
```

Each change waits on a person, who sees the trigger it would set, unless the agent's policy allows
it. The audit records the agent as who made it, and `wardrik triggers` lists the trigger as any
other. An agent its file declares keeps the triggers its file lists; one defined over the HTTP API
changes its own. See [Policy and approvals](/concepts/policy/).

## Hearing what it did

An agent nobody is watching can say what each run answered. `notify` with `finished` sends a turn's
answer to a target in `config.yaml`:

```yaml
notify: {to: [ops], on: [parked, failed, finished]}
```

See [Send notices](/build/notices/) for the targets.

## In a cluster

A trigger runs once in the cluster, on whichever node holds it. Its next run is written to the
store before the agent is asked, so each run happens once, and when its node is lost it carries on
from the store on another.

## Changing and removing triggers

`wardrik reload` gives each agent the triggers its file lists now and removes the others. A changed
`every` starts counting again from the reload; a changed prompt, `overlap`, `missed` or `jitter`
keeps the next run where it was. Removing `triggers` from a file removes all of that agent's
triggers.

## Over HTTP

An agent defined over the HTTP API lists its triggers in its definition, as a file does:

```sh
curl -X PUT -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage \
  -d '{"instructions": "You watch the incident queue.", "tools": ["linear/*"],
       "triggers": [{"name": "sweep", "every": "30m", "prompt": "Check the incident queue."}]}'
```

Putting the definition again gives the agent the triggers it lists then, and removes the others.
One trigger is set or removed at a time with a token that can `define`, which changes the
definition the daemon keeps:

```sh
curl -X PUT -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage/triggers/digest \
  -d '{"every": "0 17 * * 1-5", "prompt": "Write up what happened today."}'

curl -X DELETE -H "authorization: Bearer $TOKEN" \
  http://127.0.0.1:4747/v1/agents/acme/triage/triggers/digest
```

The body is one trigger without its `name`, which is the path's. `GET .../definition` lists the
triggers as they stand. An agent with no definition kept answers `404`, and one a file declares
has the triggers its file lists: the HTTP API refuses, with `409`, to change them.
