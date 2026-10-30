# Events and the audit

Every agent's events are kept, to read back, follow, or carry into your app. Everything people did
through Wardrik is in the audit.

## Follow them into your app

A listener hands each event to your module with the cursor past it. Store the cursor with your own
work, and the listener carries on from it after a restart:

```elixir
defmodule MyApp.Runs do
  use Wardrik.Listener, wardrik: MyApp.Wardrik, types: ["wardrik.run.completed"]

  @impl true
  def handle(%Wardrik.Event{} = event, listener) do
    MyApp.Repo.transaction(fn ->
      MyApp.Repo.insert!(MyApp.Run.from(event), on_conflict: :nothing)
      MyApp.Cursors.put!("runs", listener.cursor)
    end)

    :ok
  end

  @impl true
  def cursor(_listener), do: MyApp.Cursors.get("runs")
end
```

Let Wardrik start it, so it starts after what it follows:

```elixir
config :my_app, MyApp.Wardrik, listeners: [MyApp.Runs]
```

Or add it to your own supervision tree, after `MyApp.Wardrik`.

### Options

  * `:wardrik` - required. The module that uses Wardrik, as `MyApp.Wardrik`.
  * `:resources` - agents to follow. Every agent unless set.
  * `:types` - event types to follow. Every type unless set.
  * `:after` - the cursor to start after, unless you define `cursor/1`. Without one, it reads
    what's written once it starts.

Each event is handed over at least once. Store the cursor in the same transaction as what
`handle/2` did, and drop repeats by the event's `id`. If `handle/2` raises or returns anything but
`:ok`, the listener restarts from `cursor/1`.

## Read and follow

```elixir
{:ok, cursor} = Wardrik.Events.head(scope)

Wardrik.Events.list(scope, after: cursor, limit: 2)
#=> {:ok,
#=>  %Wardrik.Page{
#=>    events: [
#=>      %Wardrik.Event{type: "wardrik.run.started", subject: "runs/0af76519...", time: ~U[2026-10-23 09:00:01Z], data: %{"run" => ...}, ...},
#=>      %Wardrik.Event{type: "wardrik.message.started", ...}
#=>    ],
#=>    next: "eyJhY21lL3RyaWFnZSI6NDN9"
#=>  }}

{:ok, stream} = Wardrik.Events.stream_list(scope, after: cursor, resources: ["acme/*"])

for {%Wardrik.Event{type: type}, _cursor} <- stream, do: IO.puts(type)
```

`list/2` reads after the cursor, or from the start without one. `stream_list/2` reads after the
cursor, or from what's written next without one, then keeps following. Where a log was trimmed past
the cursor, a `wardrik.events.dropped` event says so, and reading goes on from the oldest event
kept.

Each event is a CloudEvent, with `data` shaped as the protocol describes its type. A scope only
sees the events of agents it can see, and a cursor only names those agents.

## The audit

Everything people did through Wardrik, for the whole deployment:

```elixir
Wardrik.Audit.list(scope, limit: 50)
#=> {:ok,
#=>  %Wardrik.Page{
#=>    events: [%Wardrik.Event{type: "wardrik.agent.defined", data: %{"actor" => %{"id" => "acme/@maria"}, ...}, ...}],
#=>    next: 1
#=>  }}
```

Pass `next` as `starting_after:` to read the following page.
