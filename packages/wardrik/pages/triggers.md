# Trigger agents

> See it in action: [Scheduled runs and webhooks](../notebooks/triggers-demo.livemd)

A trigger asks an agent something on a clock, when a feed has new entries, or when a webhook
arrives.

## Setup

Triggered runs call the model, so set your Anthropic key. `:vault_keys` seals the webhook's secret.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.10"}])

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
    vault_keys: [Wardrik.Vault.generate_key()]
  )

scope = Wardrik.as(MyApp.AgentRuntime, "maria")

{:ok, _vsn} =
  Wardrik.Vault.put(
    MyApp.AgentRuntime.Vault,
    %Wardrik.Vault.Secret{principal: Wardrik.principal("maria"), name: "HOOK", value: "s3cret"},
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

See `Wardrik.Triggers.Trigger` for trigger fields, defaults, and accepted values.

- `settle` cancels a turn waiting on an answer nobody gave, then asks. It skips a turn still working.
  The audit gets `wardrik.agent.cancelled` with the trigger's name.
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

## Feeds

- A trigger with `feed` asks only when the feed has entries it hasn't seen. The prompt lists up
  to 20.
- The first run only records what the feed holds.

## Telemetry

`[:wardrik_triggers, :fired]` after every run. Metadata: `:agent_id`, `:trigger`, `:status`.

## Triggers on their own

`Wardrik.Triggers` runs without Wardrik, for `WardrikCore` agents. Your app gives it a
`Wardrik.Triggers.Target`, which asks the agent, decides what to do when it's busy, and finds
webhook secrets. Wardrik's own is `Wardrik.Triggers.Agents`.

```elixir
children = [
  {Wardrik.Store, store},
  {WardrikCore, backend: {Wardrik.Store.Durable, store: store}},
  {Wardrik.Triggers, name: MyApp.Triggers, store: store, target: {MyApp.Triggered, []}}
]

:ok =
  Wardrik.Triggers.put(MyApp.Triggers, "agt_digest", [
    %{"name" => "daily", "every" => "0 9 * * *", "prompt" => "Write today's update."}
  ])

{:ok, _trigger} =
  Wardrik.Triggers.set(MyApp.Triggers, "agt_digest", %{"name" => "weekly", "every" => "@weekly", "prompt" => "Recap"})

:ok = Wardrik.Triggers.remove(MyApp.Triggers, agent_id: "agt_digest", name: "weekly")
```

Pass each webhook's raw body and headers to `Wardrik.Triggers.deliver/2`. In a `Plug.Router`:

```elixir
post "/hooks/:agent/:trigger" do
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  request = %{body: body, headers: Map.new(conn.req_headers)}

  case Wardrik.Triggers.deliver(MyApp.Triggers, agent_id: agent, name: trigger, request: request) do
    :ok -> send_resp(conn, 202, "")
    {:error, :not_found} -> send_resp(conn, 404, "")
    {:error, _busy} -> send_resp(conn, 503, "")
  end
end
```

- Read the body before `Plug.Parsers` does. A signature covers the exact bytes.
- Each request is asked once, keyed by `Idempotency-Key`, `webhook-id`, or its body.
