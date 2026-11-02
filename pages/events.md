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
{:ok, cursor} = Wardrik.Events.head(scope)

{:ok, _} = Wardrik.Agent.define(scope, "agt_assistant", model: "anthropic:claude-haiku-4-5")

Wardrik.Events.list(scope, after: cursor, limit: 2)
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
- `agents:` names agents by ID, with their conversations. Every agent the scope may see unless set.
- Each event is a CloudEvent. `agent` and `conversation` say which log it's in.
- A scope sees only agents your authorizer allows `agent.events` on.
- Where a log was trimmed past the cursor, a `wardrik.events.dropped` event says so.

## Listeners

A listener hands each event to your module, with the cursor past it:

```elixir
defmodule MyApp.Started do
  use Wardrik.Listener, wardrik: MyApp.AgentRuntime, types: ["wardrik.agent.started"]

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
