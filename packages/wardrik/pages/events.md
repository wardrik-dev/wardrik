# Events and the audit

> See it in action: [Event logs](../notebooks/events-demo.livemd)

Every agent's events are kept, to read back or follow. What people did is in the audit.

## Setup

Nothing here calls a model.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.12"}])

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

## Views

A view folds an agent's events into what a screen shows, and keeps it current as more arrive:

```elixir
{:ok, %Wardrik.Page{events: events}} = Wardrik.Agent.events(scope, "agt_assistant")

timeline = Wardrik.Views.Timeline.fold(events)
Wardrik.Views.Timeline.items(timeline)
#=> [%{kind: :user, text: "Hi", ...}, %{kind: :run, status: :completed, steps: [...], ...}]

runs = Wardrik.Views.Runs.fold(events)
Wardrik.Views.Runs.totals(runs)
#=> %{runs: 1, failed: 0, tool_calls: 0, cost_micro_usd: 0, ...}
```

- Fold each streamed event in with `apply/2`. `Wardrik.Views.Timeline.touched/1` names the items
  it changed, or `:reset` where the conversation was cleared.
- A delegate's work is a `:subagent` step of its own, never the agent's answer.

## Listeners

A listener calls your module for each selected agent event. It includes the cursor after that event:

```elixir
defmodule MyApp.Started do
  use Wardrik.Listener,
    wardrik: MyApp.AgentRuntime,
    agents: ["agt_digest"],
    types: ["wardrik.agent.started"]

  @impl true
  def handle(%Wardrik.Event{} = event, listener) do
    IO.puts("Started #{event.agent}")
    :persistent_term.put(__MODULE__, listener.cursor)
    :ok
  end

  @impl true
  def cursor(_listener), do: :persistent_term.get(__MODULE__, nil)
end

{:ok, _} = Supervisor.start_link([MyApp.Started], strategy: :one_for_one)

Wardrik.Agent.define(scope, "agt_digest", model: "anthropic:claude-haiku-4-5")
# Started agt_digest
```

- Save the cursor in the same transaction as your work. `cursor/1` returns it after a restart.
- Each event comes at least once. Drop repeats by `id`.
- If `handle/2` raises or doesn't return `:ok`, the listener restarts from `cursor/1`.
- Start it from Wardrik's `listeners: [MyApp.Started]`, or after Wardrik in your tree.
- See `Wardrik.Listener` for its options.

## Sinks

To send every agent's events on, to a warehouse, a queue or tracing, give Wardrik a sink:

```elixir
defmodule MyApp.Shipper do
  @behaviour Wardrik.Sink

  @impl true
  def handle_event(%Wardrik.Event{} = event, _opts), do: IO.puts("#{event.agent}: #{event.type}")
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.Shipped,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []},
    sinks: [MyApp.Shipper]
  )

Wardrik.Agent.define(Wardrik.as(MyApp.Shipped, "maria"), "agt_notes", model: "anthropic:claude-haiku-4-5")
# agt_notes: wardrik.agent.started
```

- A sink gets each event once it's kept, and the audit's changes, with its `sequence` in its log.
- It runs in the process that wrote the event, often the agent's. Return quickly.
- An event whose node stops before the sink takes it isn't sent. Read on from that agent's
  `sequence` with `list/2`, or follow the agents you can't miss with a listener.

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

## The event log on its own

`Wardrik.EventLog` keeps the logs Wardrik reads. It runs without Wardrik too, over any
`Wardrik.Store`:

```elixir
store = Wardrik.Store.ETS.new(name: MyApp.Store)

children = [
  {Wardrik.Store, store},
  {Wardrik.EventLog, name: MyApp.Events, store: store, deployment: "acme-prod", sinks: [MyApp.Shipper]}
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)
```

- Give it to each `WardrikCore` agent as `events: {Wardrik.EventLog, MyApp.Events}`.
- `Wardrik.Store.ETS` keeps events in memory. `Wardrik.Store.EKV` keeps them on disk.
- See `Wardrik.EventLog.start_link/1` for the options.

Read, follow and write a log:

```elixir
{:ok, %{events: events, next: next}} = Wardrik.EventLog.page(MyApp.Events, ["agt_1"], limit: 100)

{:ok, stream} = Wardrik.EventLog.stream(MyApp.Events, [{"agt_1", "C1"}], after: next)

data = %{"trigger" => %{"name" => "daily"}, "status" => "asked"}
:ok = Wardrik.EventLog.append(MyApp.Events, "agt_1", {"trigger.fired", "triggers/daily", data})

change = {"agent.forgotten", "agents/agt_1", %{"agent" => %{"id" => "agt_1"}}}
:ok = Wardrik.EventLog.record(MyApp.Events, change, actor: %Wardrik.Principal{id: "user_42"})
```

- Events here are CloudEvent maps with string keys, as they're kept.
- `"agt_1"` reads the agent and all its conversations. `{"agt_1", "C1"}` reads one.
- The stream also carries live events, like `wardrik.message.delta`, which are never kept. No kept
  event is missed or repeated as it moves from the log to live delivery.
- `append/4` writes to an agent's log. `record/3` writes to the audit.
- `subscribe(MyApp.Events, :all)` sends every agent's events, live ones too, to the calling
  process.

What an agent is doing now:

```elixir
Wardrik.EventLog.activity(MyApp.Events, "agt_1")
#=> %{"doing" => [%{"type" => "wardrik.tool_call.started", ...}], "since" => "...", "pending" => 1}
```

Write your own view with `Wardrik.EventLog.View`.
