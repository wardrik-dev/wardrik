# Trigger agents

> See it in action: [Agents that wake themselves](../notebooks/triggers-demo.livemd)

A trigger asks an agent something on a clock, when a feed has new entries, or when a webhook
arrives.

## Setup

Triggered runs call the model, so set your Anthropic key. `:keys` seals the webhook's secret.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.2"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer
  def authorize(_request, _opts), do: :ok
end

# Every agent works for Maria.
defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver
  def resolve(_request, _opts), do: {:ok, %Wardrik.Resolved{principal: Wardrik.principal("maria")}}
end

System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []},
    keys: [WardrikVault.generate_key()]
  )

scope = Wardrik.as(MyApp.AgentRuntime, "maria")

{:ok, _vsn} =
  WardrikVault.put(
    MyApp.AgentRuntime.Vault,
    %WardrikVault.Secret{principal: Wardrik.principal("maria"), name: "HOOK", value: "s3cret"},
    kind: :signing_secret
  )
```

## Define them

```elixir
Wardrik.Agent.define(scope, "agt_digest",
  model: "anthropic:claude-haiku-4-5",
  triggers: [
    %{name: "daily", every: "0 9 * * *", timezone: "America/Los_Angeles", prompt: "Write today's update."},
    %{name: "rivals", every: "6h", feed: ["https://example.com/feed.xml"], prompt: "What changed?"},
    %{name: "issues", webhook: %{secret: "${HOOK}"}, prompt: "Triage it."}
  ]
)
#=> {:ok, %Wardrik.Agent{id: "agt_digest", next_run: ~U[...], ...}}
```

- A triggered run is an ordinary message. It wakes a sleeping agent.
- Each run writes `wardrik.trigger.fired` to the agent's log.

| Key | Means |
| --- | --- |
| `every` | Cron, as `0 9 * * 1` or `@daily`, or an interval of a minute or more, as `30m`. |
| `timezone` | For cron. `Etc/UTC` unless set. |
| `prompt` | What the agent is asked. |
| `prompt_file` | A file in its workspace to read each run, instead of `prompt`. Needs `files`. |
| `name` | `trigger-1`, `trigger-2` and so on unless set. |
| `overlap` | `skip` or `queue` when the agent is busy. `skip` unless set, `queue` for webhooks. |
| `missed` | `run_once` or `skip` what was missed while nothing ran. |
| `jitter` | Up to this many seconds added to each run. |
| `feed` | RSS or Atom URLs. Asks only for new entries, up to 20. The first run only reads. |
| `webhook` | `secret`, as `${NAME}`, and `verify`, `shared` or `standard`. |

- A late run, more than a minute, runs once however many were missed.
- Set `triggers: [req_options: ...]` in Wardrik's options to change how feeds are read.

## Webhooks

A service sends `POST /v1/hooks/{agent}/{trigger}` with the secret as a bearer token, or
`POST /v1/hooks/{agent}/{trigger}/{secret}` if it only takes a URL. From Elixir:

```elixir
Wardrik.Hook.deliver(scope,
  agent: "agt_digest",
  trigger: "issues",
  body: ~s({"action":"opened"}),
  headers: %{"authorization" => "Bearer s3cret"}
)
#=> :ok
```

- `${NAME}` names a `:signing_secret` of whoever the agent works for, in Wardrik's vault.
- `verify: standard` checks [Standard Webhooks](https://www.standardwebhooks.com/) signatures.
- A request that doesn't prove itself returns `not_found`. Each request is asked once.
- `unavailable` means the service should send it again later.

## Change one

```elixir
Wardrik.Agent.trigger_set(scope,
  agent: "agt_digest",
  trigger: "daily",
  every: "0 8 * * *",
  prompt: "Write it."
)
#=> {:ok, %Wardrik.Trigger{name: "daily", every: "0 8 * * *", ...}}

Wardrik.Agent.trigger_remove(scope, agent: "agt_digest", trigger: "daily")
#=> {:ok, %Wardrik.Trigger{name: "daily", ...}}
```

- Defining the agent again replaces all its triggers.
- A trigger whose `every` and `timezone` stay keeps its next run.
- In a cluster, each run is claimed in the store, so it runs once.
