# Events and the audit

> See it in action: [See everything an agent did](../notebooks/events-demo.livemd)

Every agent's events are kept, to read back or follow. What people did is in the audit.

## Setup

Nothing here calls a model.

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

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []}
  )

scope = Wardrik.as(MyApp.AgentRuntime, "maria")
```

## Read and follow

```elixir
{:ok, cursor} = Wardrik.Events.head(scope, agents: ["agt_assistant"])

{:ok, _} = Wardrik.Agent.define(scope, "agt_assistant", model: "anthropic:claude-haiku-4-5")

Wardrik.Events.list(scope, agents: ["agt_assistant"], after: cursor, limit: 2)
#=> {:ok,
#=>  %Wardrik.Page{
#=>    events: [%Wardrik.Event{type: "wardrik.agent.started", agent: "agt_assistant", ...}],
#=>    next: "W1siYWd0X2Fzc2lzdGFudCIsbnVsbCwxXV0"
#=>  }}

{:ok, stream} = Wardrik.Events.stream_list(scope, after: cursor, agents: ["agt_assistant"])

Enum.take(stream, 1)
#=> [{%Wardrik.Event{type: "wardrik.agent.started", ...}, "W1siYWd0X2Fzc2lzdGFudCIsbnVsbCwxXV0"}]
```

- Pass `next` as `after:` to read on. Without `after:`, `list/2` starts at the beginning.
- `stream_list/2` never ends. It yields `{event, cursor}`. Without `after:`, it starts with new events.
- `agents:` names the agents to read by ID, with their conversations.
- Each event is a CloudEvent. `agent` and `conversation` say which log it's in.
- A scope sees only agents your authorizer allows `agent.events` on.
- Where a log was trimmed past the cursor, a `wardrik.events.dropped` event says so.

## Sinks

To send every agent's events on, to a warehouse, a queue or tracing, give Wardrik a sink:

```elixir
defmodule MyApp.Shipper do
  @behaviour WardrikEvents.Sink

  @impl true
  def handle_event(event, _opts), do: IO.puts("#{event["agent"]}: #{event["type"]}")
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.Shipped,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []},
    sinks: [MyApp.Shipper]
  )

Wardrik.Agent.define(Wardrik.as(MyApp.Shipped, "maria"), "agt_digest", model: "anthropic:claude-haiku-4-5")
# agt_digest: wardrik.agent.started
```

- A sink gets each event once it's kept, and the audit's changes, with its `sequence` in its log.
- It runs in the process that wrote the event, often the agent's. Return quickly.
- An event whose node stops before the sink takes it isn't sent. Read on from that agent's
  `sequence` with `list/2`.
- `:telemetry` gets every agent event too. See `WardrikCore.Telemetry`.

## The audit

What people did through Wardrik. It needs `deployment.audit` on `{:deployment, name}`:

```elixir
Wardrik.Audit.list(scope, limit: 50)
#=> {:ok,
#=>  %Wardrik.Page{
#=>    events: [%Wardrik.Event{type: "wardrik.agent.defined", data: %{"actor" => %{"id" => "maria"}, ...}}, ...],
#=>    next: 2
#=>  }}
```

Pass `next` as `starting_after:` to read on.
