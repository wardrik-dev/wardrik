# wardrik_trigger

Triggers for [Wardrik](../wardrik) agents: a prompt an agent is asked on a
clock, kept in the store the fleet runs on, so one node in the cluster owns
each trigger and another carries it on when that node is lost.

```elixir
def deps do
  [{:wardrik_trigger, "~> 0.1.0"}]
end
```

```elixir
# lib/my_app/application.ex
children = [Wardrik, WardrikTrigger]
```

```elixir
WardrikTrigger.put(~A"acme/triage", "sweep",
  every: "*/30 * * * *",
  prompt: "Check the incident queue.")

WardrikTrigger.sync(~A"acme/triage", [
  WardrikTrigger.new("digest", every: "0 17 * * 1-5", prompt: "Write up today.")
])
```

`every` is a five-field cron expression read in UTC, or a duration of at
least a minute, as `"30m"`. A trigger writes down its next run before it
asks the agent, so a firing lost to a crash is not made again, and it
announces each firing on the agent's events as `{:trigger_fired, name,
outcome}`.

A trigger watches a source: the clock, which asks the agent on every run,
unless it names another, which asks only when it finds something new, with
what it found under the prompt. A source is a module implementing
`WardrikTrigger.Source`, registered under the key a trigger names it by:

```elixir
# mix.exs of the package that ships it
def application, do: [env: [wardrik_trigger_sources: [feed: MyApp.Feed]]]
```

```elixir
WardrikTrigger.put(~A"acme/growth", "mentions",
  every: "1h",
  prompt: "New mentions of Acme. Which deserve a reply?",
  source: {MyApp.Feed, "https://example.com/alerts.xml"})
```

In the daemon, an agent's definition lists its triggers, in its file or in
the body of `PUT /v1/agents/{id}`:

```yaml
triggers:
  - name: sweep
    every: "*/30 * * * *"
    prompt: Check the incident queue.
```
