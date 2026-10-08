---
title: Run an agent on a schedule
description: Ask an agent something on a clock, with cron or an interval, and give it a checklist it can edit.
sidebar:
  order: 1
---

An agent can be asked something on a clock. A schedule is part of the agent's definition, here its
agent file:

```yaml title="~/.config/wardrik/agents/triage.md"
---
model: anthropic:claude-sonnet-5
tools: [linear/*]
schedule:
  - name: sweep
    every: 30m
    prompt: Check the incident queue, and say what is new.
  - name: digest
    every: "0 17 * * 1-5"
    prompt: Write up what happened today.
---
You watch the incident queue.
```

Read the agent files again, and see when each schedule runs:

```sh
wardrik reload
wardrik schedules
```

```
2 schedules:
  default/triage/digest  0 17 * * 1-5  next in 3h 12m  not run yet
  default/triage/sweep  every 30m  next in 29m  not run yet
```

`wardrik status` and `wardrik ls` show when each agent next runs, and `wardrik show` lists its
schedules.

A scheduled run is an ordinary message to the agent. It is in the agent's history like any other,
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
`1d`. It is measured from when the schedule was set or last ran, not from the top of the hour, so
`1d` set at 14:20 runs at 14:20.

`jitter` adds up to that many seconds to each run, so several schedules on the same minute do not
all ask at once:

```yaml
every: "0 * * * *"
jitter: 120
```

A new schedule runs first when it next comes round, not as soon as it is set.

## When the agent is busy

By default a run that finds the agent running a turn, or waiting on a person, lets it be, and
`wardrik schedules` says the run was skipped. `overlap: queue` asks it anyway:

- a running turn stops at its next step, and the scheduled message is answered in the turn after,
  with what the running one left;
- an agent waiting on a person answers it once what it waits on is decided.

```yaml
overlap: queue
```

## When the daemon was down

A run more than a minute late, because the daemon was stopped or every node was lost, runs once when
the schedule is next running, however many runs were missed. `missed: skip` lets them go instead:

```yaml
missed: skip
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
schedule:
  name: heartbeat
  every: 30m
  prompt_file: HEARTBEAT.md
```

The file is read as the run happens, so one that does not exist yet is the agent's to find out
about. See [Files and memory](/concepts/files-and-memory/).

## Hearing what it did

An agent nobody is watching can say what each run answered. `notify` with `finished` sends a turn's
answer to a target in `config.yaml`:

```yaml
notify: {to: [ops], on: [parked, failed, finished]}
```

See [Approve calls from Slack](/guides/slack/) for the targets.

## In a cluster

A schedule runs once in the cluster, on whichever node holds it. Its next run is written to the
store before the agent is asked, so each run happens once, and when its node is lost it carries on
from the store on another.

## Changing and removing schedules

`wardrik reload` gives each agent the schedules its file lists now and removes the others. A changed
`every` starts counting again from the reload; a changed prompt, `overlap`, `missed` or `jitter`
keeps the next run where it was. Removing `schedule` from a file removes all of that agent's
schedules.

## Over HTTP

An agent defined over the HTTP API lists its schedules in its definition, as a file does:

```sh
curl -X PUT -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage \
  -d '{"instructions": "You watch the incident queue.", "tools": ["linear/*"],
       "schedule": [{"name": "sweep", "every": "30m", "prompt": "Check the incident queue."}]}'
```

Putting the definition again gives the agent the schedules it lists then, and removes the others.
One schedule is set or removed at a time with a token that can `define`, which changes the
definition the daemon keeps:

```sh
curl -X PUT -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage/schedules/digest \
  -d '{"every": "0 17 * * 1-5", "prompt": "Write up what happened today."}'

curl -X DELETE -H "authorization: Bearer $TOKEN" \
  http://127.0.0.1:4747/v1/agents/acme/triage/schedules/digest
```

The body is one schedule without its `name`, which is the path's. `GET .../definition` lists the
schedules as they stand. An agent with no definition kept answers `404`, and one a file declares
has the schedules its file lists: the HTTP API refuses, with `409`, to change them.
