# Trigger agents

A trigger asks an agent something without anyone typing: on a clock, when a feed has new entries,
or when a service sends a webhook. Triggers are part of a definition:

```elixir
Wardrik.Agent.define(scope, "acme/digest",
  model: "anthropic:claude-haiku-4-5",
  tools: ["github/*"],
  triggers: [
    %{
      name: "daily",
      every: "0 9 * * *",
      timezone: "America/Los_Angeles",
      prompt: "Write today's update."
    },
    %{name: "rivals", every: "6h", feed: ["https://rivalco.example/rss"], prompt: "What changed?"},
    %{name: "issues", webhook: %{secret: "${ISSUES_HOOK_SECRET}"}, prompt: "Triage it."}
  ]
)
```

A triggered run is an ordinary message to the agent, and wakes an agent that sleeps. Each run
writes `wardrik.trigger.fired` to the agent's log, saying whether it asked, found nothing new,
found the agent busy, or failed.

## Keys

| Key | Means |
| --- | --- |
| `every` | A cron expression, as `0 9 * * 1` or `@daily`, or an interval of at least a minute, as `30m`, `2h` or `1d`. |
| `timezone` | The time zone a cron expression is read in, as `Europe/Berlin`. `Etc/UTC` unless set. |
| `prompt` | What the agent is asked. |
| `prompt_file` | Instead of `prompt`, a file in the agent's workspace it reads and follows each run, so it can edit its own checklist. Needs `files` in `tools`. |
| `name` | The trigger's name. `trigger-1`, `trigger-2` and so on, by position, unless set. |
| `overlap` | `skip` leaves a busy agent be; `queue` asks it anyway. `skip` unless set, `queue` for a webhook. |
| `missed` | `run_once` runs once for what was missed while nothing ran; `skip` lets it go. |
| `jitter` | Up to this many seconds added to each run. |
| `feed` | An RSS or Atom feed's URL, or a list of them. |
| `webhook` | Instead of `every`: `secret`, as `${NAME}`, and `verify`, `shared` or `standard`. |

## On a clock

A cron expression is read in `timezone`.

  * A time the clocks skip runs at the first instant after the gap.
  * A time the clocks repeat runs on its first pass only.
  * An interval counts from when the trigger was set or last ran.
  * A run more than a minute late runs once, however many were missed, unless `missed: skip`.

## Watching a feed

A trigger with `feed` asks only when a feed has entries it hasn't seen. Up to 20 of them go under
the prompt. The first run only notes what each feed holds.

To change how feeds are read, set `triggers: [req_options: ...]` in Wardrik's config.

## Receiving a webhook

A service sends requests to `POST /v1/hooks/{agent}/{trigger}`, with the secret as a bearer token.
A service that only takes a URL sends them to `POST /v1/hooks/{agent}/{trigger}/{secret}` instead;
keep that URL as private as a token. With `verify: standard`, requests are signed as
[Standard Webhooks](https://www.standardwebhooks.com/) describes.

`${NAME}` names a credential of the agent's, kept in Wardrik's vault; see
[Credentials](credentials.md). A request that doesn't prove itself returns `not_found`. Each
request is asked about once.

From Elixir, deliver the request as it came, with its raw body and headers:

```elixir
:ok = Wardrik.Hook.deliver(scope, "acme/triage", "issues", body: body, headers: headers)
```

`unavailable` means the agent can't be asked now. The service should send it again later.

## Changing triggers

Define the agent again to replace its triggers. To change one at a time:

```elixir
Wardrik.Agent.trigger_set(scope, "acme/digest", "daily", every: "0 8 * * *", prompt: "Write it.")
#=> {:ok,
#=>  %Wardrik.Trigger{
#=>    name: "daily",
#=>    every: "0 8 * * *",
#=>    prompt: "Write it.",
#=>    overlap: :skip,
#=>    missed: :run_once,
#=>    ...
#=>  }}

Wardrik.Agent.trigger_remove(scope, "acme/digest", "daily")
#=> {:ok, %Wardrik.Trigger{name: "daily", ...}}
```

`trigger_set/4` needs an agent with a definition, and returns `not_found` otherwise. A trigger
whose `every` and `timezone` don't change keeps its next run. Each change is recorded in the audit.

## In a cluster

Every node runs triggers. Each run is claimed in the store, so it runs once in the cluster, and a
lost node's triggers carry on from another node.
