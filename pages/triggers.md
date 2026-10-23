# Trigger agents

A trigger asks an agent something without anyone typing: on a clock, when a feed it watches has new
entries, or when a service sends it a webhook. Triggers are part of a definition:

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

A triggered run is an ordinary message to the agent. A trigger wakes an agent that sleeps, and each
run writes `wardrik.trigger.fired` into the agent's log, saying whether it asked, found nothing new,
found the agent busy, or failed.

| Key | Means |
| --- | --- |
| `every` | a cron expression, as `0 9 * * 1` or `@daily`, or an interval of at least a minute, as `30m`, `2h` or `1d` |
| `timezone` | the time zone a cron expression is read in, as `Europe/Berlin`; `Etc/UTC` unless set |
| `prompt` | what the agent is asked |
| `name` | the trigger's name; `trigger-1`, `trigger-2` and so on by its place unless set |
| `overlap` | `skip` leaves a busy agent be, `queue` asks it anyway; `skip` unless set, `queue` for a webhook |
| `missed` | `run_once` runs once for what was missed while nothing ran, `skip` lets it go |
| `jitter` | up to this many seconds added to each run |
| `feed` | an RSS or Atom feed's URL, or a list of them |
| `webhook` | `secret`, as `${NAME}`, and `verify`, `shared` or `standard`, in place of `every` |

`prompt_file` answers `not_supported` until agents have files.

## On a clock

A cron expression is read on `timezone`'s clock. A time the clocks skip runs at the first instant
after the gap, and a time they repeat runs on its first pass only. An interval counts from when the
trigger was set or last ran. A run more than a minute late runs once, however many were missed,
unless `missed: skip`.

## Watching a feed

A trigger with `feed` asks only when a feed holds entries it hasn't seen, with up to 20 of them
under the prompt. Its first run only notes what each feed holds. Give `triggers: [req_options: ...]`
to `Wardrik.new/1` to change how feeds are read.

## Receiving a webhook

A service sends requests to `POST /v1/hooks/{agent}/{trigger}`, with the secret as a bearer token,
or to `.../{trigger}/{secret}` for a service that only takes a URL. With `verify: standard`, it's
signed as [Standard Webhooks](https://www.standardwebhooks.com/) says. The secret `${NAME}` names is
the agent's credential, kept in Wardrik's vault; see [Credentials](credentials.md). A request that
doesn't prove itself answers `not_found`, and each request is asked about once.

From Elixir, deliver the request as it came, raw body and headers:

```elixir
:ok = Wardrik.Hook.deliver(scope, "acme/triage", "issues", body: body, headers: headers)
```

## Changing triggers

Define the agent again to give it the triggers it lists then. To change one at a time:

```elixir
{:ok, %Wardrik.Trigger{}} =
  Wardrik.Agent.trigger_set(scope, "acme/digest", "daily", every: "0 8 * * *", prompt: "Write it.")

{:ok, _removed} = Wardrik.Agent.trigger_remove(scope, "acme/digest", "daily")
```

A trigger whose `every` and `timezone` stay keeps its next run. Each change is recorded in the
audit.

## In a cluster

Every node runs triggers, and each run is claimed in the store, so it runs once in the cluster, and
a lost node's triggers carry on from another.
