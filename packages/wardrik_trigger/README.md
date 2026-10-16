# wardrik_trigger

Triggers for [Wardrik](../wardrik) agents: a prompt an agent is asked on a
clock, or when a source it watches finds something or is sent it, kept in
the store the fleet runs on, so one node in the cluster owns
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
  WardrikTrigger.new("digest",
    every: "0 17 * * 1-5",
    timezone: "Europe/Berlin",
    prompt: "Write up today.")
])
```

`every` is a five-field cron expression, read in `timezone`, `Etc/UTC`
unless it names another, or a duration of at least a minute, as `"30m"`,
which counts elapsed time. A trigger writes down its next run before it
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

A webhook is a trigger of its own kind, `WardrikTrigger.Webhook`: it has no
clock, and asks the agent as each request a service sends arrives, through
`WardrikTrigger.deliver/3`, which makes `WardrikTrigger` the host's
`Wardrik.Triggers`. A request presents the trigger's secret, or is signed
as the Standard Webhooks spec says, checked against a secret the host's
`:secrets` reads by name for the trigger's agent, so each org keeps its own,
or from the environment where the host gives none; a host registers a
`WardrikTrigger.Webhook.Verifier` of its own for any other signature. A
request sent again is asked about once.

Each kind implements `WardrikTrigger.Kind`, its process key, the server that
runs it, and how it is written as text, so `put/2`, `sync/2` and the listings
take every kind alike, and a new kind is a struct, a server and that protocol.

```elixir
children = [
  {Wardrik.Core, host: Wardrik.Host.new(triggers: WardrikTrigger)},
  {WardrikTrigger, secrets: &MyApp.Vault.secret/2}
]

WardrikTrigger.put(~A"acme/triage", WardrikTrigger.Webhook.new("issues",
  secret: "ISSUES_HOOK_SECRET",
  prompt: "An event is below. Triage it."))
```

In the daemon, an agent's definition lists its triggers, in its file or in
the body of `PUT /v1/agents/{id}`:

```yaml
triggers:
  - name: sweep
    every: "*/30 * * * *"
    prompt: Check the incident queue.
```
