# Events and the audit

Every agent's events are kept, to read back, follow, or carry into your app, and everything people
did through Wardrik is in the audit.

## Follow them into your app

A listener hands each event to your module, with the cursor past it, so you keep your place with
your own work:

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

Let your Wardrik start it, so it starts after what it follows:

```elixir
config :my_app, MyApp.Wardrik, listeners: [MyApp.Runs]
```

Or add it to your own supervision tree, after `MyApp.Wardrik`. It takes `resources:` (every agent
unless set), `types:` (every type unless set) and `after:`. Without a cursor, it reads from what's
written once it starts.

Each event is handed over at least once: keep the cursor with what `handle/2` did, in one
transaction, and drop a repeat by the event's `id`. A `handle/2` that raises restarts it, from
`cursor/1`.

## Read and follow

```elixir
{:ok, cursor} = Wardrik.Events.head(scope)
{:ok, %Wardrik.Page{events: events, next: next}} = Wardrik.Events.list(scope, after: cursor)
{:ok, stream} = Wardrik.Events.stream_list(scope, after: cursor, resources: ["acme/*"])

for {%Wardrik.Event{type: type}, cursor} <- stream, do: IO.puts(type)
```

Each event is a CloudEvent, with its `data` as the protocol describes its type. Notice that a scope
only ever sees the events of the agents it can see, and a cursor only names those agents.

## The audit

Everything people did through Wardrik, for the deployment:

```elixir
{:ok, %Wardrik.Page{events: changes, next: next}} = Wardrik.Audit.list(scope, limit: 50)
```
