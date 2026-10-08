# wardrik_schedule

Schedules for [Wardrik](../wardrik) agents: a prompt an agent is asked on a
clock, kept in the store the fleet runs on, so one node in the cluster owns
each schedule and another carries it on when that node is lost.

```elixir
def deps do
  [{:wardrik_schedule, "~> 0.1.0"}]
end
```

```elixir
# lib/my_app/application.ex
children = [Wardrik, WardrikSchedule]
```

```elixir
WardrikSchedule.put(~A"acme/triage", "sweep",
  every: "*/30 * * * *",
  prompt: "Check the incident queue.")

WardrikSchedule.sync(~A"acme/triage", [
  WardrikSchedule.new("digest", every: "0 17 * * 1-5", prompt: "Write up today.")
])
```

`every` is a five-field cron expression read in UTC, or a duration of at
least a minute, as `"30m"`. A schedule writes down its next run before it
asks the agent, so a firing lost to a crash is not made again, and it
announces each firing on the agent's events as `{:schedule_fired, name,
outcome}`.

In the daemon, an agent's definition lists its schedules, in its file or in
the body of `PUT /v1/agents/{id}`:

```yaml
schedule:
  - name: sweep
    every: "*/30 * * * *"
    prompt: Check the incident queue.
```
