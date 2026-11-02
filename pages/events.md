# Events and the audit

Every agent's events are kept, to read back, follow, or carry into your app. Everything people did
through Wardrik is in the audit.

> See it in action: [See everything an agent did](../notebooks/events-demo.livemd)

## Setup

In a fresh IEx session:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.2"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer

  @impl true
  def authorize(_request, _opts), do: :ok
end

defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver

  # Every agent here works for Maria.
  @impl true
  def resolve(_request, _opts),
    do: {:ok, %Wardrik.Resolved{principal: Wardrik.principal("acme/@maria")}}
end

{:ok, _} = Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []}
  )
scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria")
```

Nothing on this page calls a model, so no provider key is needed.

## Read and follow

Take the cursor where the log stands, define an agent, and read what was written since:

```elixir
{:ok, cursor} = Wardrik.Events.head(scope)

{:ok, _agent} =
  Wardrik.Agent.define(scope, "agt_assistant",
    model: "anthropic:claude-haiku-4-5",
    instructions: "You keep Maria's notes."
  )

Wardrik.Events.list(scope, after: cursor, limit: 2)
#=> {:ok,
#=>  %Wardrik.Page{
#=>    events: [
#=>      %Wardrik.Event{
#=>        type: "wardrik.agent.started",
#=>        agent: "agt_assistant",
#=>        subject: "agents/agt_assistant",
#=>        time: ~U[2026-10-23 09:00:01Z],
#=>        data: %{"agent" => %{"id" => "agt_assistant", ...}, ...},
#=>        ...
#=>      }
#=>    ],
#=>    next: "W1siYWd0X2Fzc2lzdGFudCIsbnVsbCwxXV0"
#=>  }}
```

Pass `next` as `after:` to read on. `list/2` reads from the start without `after:`.

`stream_list/2` reads after the cursor, then keeps following. Without `after:`, it starts with
what's written next:

```elixir
{:ok, stream} =
  Wardrik.Events.stream_list(scope, after: cursor, agents: ["agt_assistant"])

Enum.take(stream, 1)
#=> [{%Wardrik.Event{type: "wardrik.agent.started", ...}, "W1siYWd0X2Fzc2lzdGFudCIsbnVsbCwxXV0"}]
```

The stream doesn't end. Each item is an event and the cursor past it.

  * Each event is a CloudEvent, with `data` shaped as the protocol describes its type.
  * `agents:` names the agents to read, by ID. Each covers the agent's conversations. Every
    agent the scope may see unless set.
  * An event's `agent` and `conversation` say which log it's in. `conversation` is `nil` for the
    agent's own.
  * A scope only sees the events of agents your authorizer allows `agent.events` on. A cursor
    only names those agents.
  * Where a log was trimmed past the cursor, a `wardrik.events.dropped` event says so. Reading goes
    on from the oldest event kept.

## Follow them into your app

A listener hands each event to your module with the cursor past it. Save the cursor, and the
listener carries on from it after a restart:

```elixir
defmodule MyApp.Started do
  use Wardrik.Listener, wardrik: MyApp.AgentRuntime, types: ["wardrik.agent.started"]

  @impl true
  def handle(%Wardrik.Event{} = event, listener) do
    IO.puts("Started #{event.subject}")
    :persistent_term.put(__MODULE__, listener.cursor)
    :ok
  end

  @impl true
  def cursor(_listener), do: :persistent_term.get(__MODULE__, nil)
end

{:ok, _} = Supervisor.start_link([MyApp.Started], strategy: :one_for_one)

Wardrik.Agent.define(scope, "agt_digest",
  model: "anthropic:claude-haiku-4-5",
  instructions: "You write Maria's daily digest."
)
# Started agents/agt_digest
```

In your app, save the cursor where you save the work, in the same transaction, as with
`MyApp.Repo.transaction/1`. Have Wardrik start the listener, so it starts after what it follows:

```elixir
config :my_app, MyApp.AgentRuntime, listeners: [MyApp.Started]
```

Or add it to your own supervision tree, after `MyApp.AgentRuntime`.

Each event is handed over at least once. Drop repeats by the event's `id`. If `handle/2` raises or
returns anything but `:ok`, the listener restarts from `cursor/1`.

### Options

  * `:wardrik` - required. The module that uses Wardrik, as `MyApp.AgentRuntime`.
  * `:agents` - the IDs of the agents to follow, as `["agt_digest"]`, each with its
    conversations. Every agent unless set. A listener reads every agent's events as your app,
    not as a scope.
  * `:types` - event types to follow. Every type unless set.
  * `:after` - the cursor to start after, unless you define `cursor/1`. Without one, it reads
    what's written once it starts.

## The audit

Everything people did through Wardrik, for the whole deployment. Reading it needs your authorizer
to allow `deployment.audit` on `{:deployment, name}`, by Wardrik's `:deployment`:

```elixir
Wardrik.Audit.list(scope, limit: 50)
#=> {:ok,
#=>  %Wardrik.Page{
#=>    events: [
#=>      %Wardrik.Event{type: "wardrik.agent.defined", data: %{"actor" => %{"id" => "acme/@maria"}, ...}, ...},
#=>      ...
#=>    ],
#=>    next: 2
#=>  }}
```

Pass `next` as `starting_after:` to read the following page.
