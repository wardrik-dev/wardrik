---
title: Follow events into your app
description: "Keep what agents do in your own tables, carry on after any restart, and show what an agent is doing as it works."
sidebar:
  order: 4.6
---

A listener follows agents' events into your app. It hands each event to your code with the cursor
past it, so you keep your place where you keep your own work, and carry on from there after any
restart. This guide keeps every run of every agent in tables of your app's own: in Postgres from
Elixir, then in SQLite from TypeScript. It builds on [Embed in your app](/build/embed/).

## 1. Let your app read the events

Your app reads as the deployment itself, `Wardrik.Principal.deployment()`. Your issuer gives it
`agent.events` on every agent, and `agent.read`, as the embed guide's
[issuer](/build/embed/#3-say-who-may-do-what) does:

```elixir
["deployment"] -> %Wardrik.Token{principal: principal, scope: MyApp.Issuer.deployment()}
```

## 2. Make its tables

One table holds the events, keyed by their CloudEvent `id`. Another holds the cursor:

```elixir title="priv/repo/migrations/20261019000000_add_agent_events.exs"
defmodule MyApp.Repo.Migrations.AddAgentEvents do
  use Ecto.Migration

  def change do
    create table(:agent_events, primary_key: false) do
      add :id, :text, primary_key: true
      add :agent, :text, null: false
      add :type, :text, null: false
      add :data, :map, null: false
      add :at, :utc_datetime_usec, null: false
    end

    create table(:wardrik_cursors, primary_key: false) do
      add :name, :text, primary_key: true
      add :cursor, :text, null: false
    end
  end
end
```

## 3. Write the listener

`use Wardrik.Listener`, then say what to do with each event in `handle/2`, and where you left off
in `cursor/1`. The event and the cursor past it go in one transaction:

```elixir title="lib/my_app/agents/runs.ex"
defmodule MyApp.Agents.Runs do
  @moduledoc """
  Keeps when each run of every agent starts and ends in this app's own
  tables, with the cursor past it in the same transaction, so a restart
  carries on where it stopped.
  """

  use Wardrik.Listener

  import Ecto.Query

  alias MyApp.Repo
  alias Wardrik.Event.Log.Entry

  @doc "The child that runs it, after Wardrik, on `wardrik`."
  def child_spec(wardrik) do
    super(
      host: wardrik,
      principal: Wardrik.Principal.deployment(),
      resources: [Wardrik.Resource.parse!("*/agent/*")],
      types: ~w(wardrik.run.started wardrik.run.completed wardrik.run.failed)
    )
  end

  # The log was trimmed past the cursor, so the events between are gone:
  # keep what the agent says of itself now in their place.
  @impl true
  def handle(%Entry{event: %{"type" => "wardrik.events.dropped"} = event} = entry, listener) do
    {:ok, snapshot} = Wardrik.agent_read(listener.scope, entry.log)
    keep(entry, %{event | "data" => %{"status" => to_string(snapshot.status.state)}}, listener.cursor)
  end

  def handle(%Entry{event: event} = entry, listener), do: keep(entry, event, listener.cursor)

  # The first start reads from the head of every log, kept at once so a
  # restart before the first event misses nothing.
  @impl true
  def cursor(listener) do
    case Repo.one(from(c in "wardrik_cursors", where: c.name == "runs", select: c.cursor)) do
      nil -> save!(Wardrik.events_head!(listener.scope, Keyword.take(listener.options, [:resources])))
      cursor -> cursor
    end
  end

  # An event comes again after a restart that cut its transaction short; the
  # id it is kept under drops the repeat.
  defp keep(entry, event, cursor) do
    {:ok, at, 0} = DateTime.from_iso8601(event["time"])
    row = %{id: event["id"], agent: to_string(entry.log), type: event["type"], data: event["data"], at: at}

    {:ok, _cursor} =
      Repo.transaction(fn ->
        Repo.insert_all("agent_events", [row], on_conflict: :nothing)
        save!(cursor)
      end)

    :ok
  end

  defp save!(cursor) do
    Repo.insert_all("wardrik_cursors", [%{name: "runs", cursor: cursor}],
      on_conflict: {:replace, [:cursor]},
      conflict_target: :name
    )

    cursor
  end
end
```

`:types` are the events it takes. A `wardrik.events.dropped` comes whatever they say, so the first
`handle/2` reads the agent's snapshot in place of what was lost.

## 4. Start it after Wardrik

```elixir title="lib/my_app/agents.ex"
def children, do: [{WardrikStore, store()}, {Wardrik, wardrik()}, {MyApp.Agents.Runs, wardrik()}]
```

Ask an agent something, and its run is in `agent_events`:

```sql
SELECT agent, type, at FROM agent_events ORDER BY at DESC LIMIT 5;
```

## From TypeScript

`wardrik.listen` hands each event to the handler of its type, with the cursor past it, and waits
for each before the next. This keeps the same tables in SQLite. Its token reads acme's agents:

```ts title="examples/runs.ts"
import { DatabaseSync } from "node:sqlite";
import { Wardrik, type WardrikEvent } from "@wardrik/sdk";

const db = new DatabaseSync("runs.db");

db.exec(`
  CREATE TABLE IF NOT EXISTS agent_events (id TEXT PRIMARY KEY, agent TEXT, type TEXT, data TEXT, at TEXT);
  CREATE TABLE IF NOT EXISTS wardrik_cursors (name TEXT PRIMARY KEY, cursor TEXT);
`);

const resources = ["acme/agent/*"];
const wardrik = new Wardrik();

const save = (cursor: string): string => {
  db.prepare(
    "INSERT INTO wardrik_cursors VALUES ('runs', ?) ON CONFLICT (name) DO UPDATE SET cursor = excluded.cursor",
  ).run(cursor);
  return cursor;
};

// The agent an event is of, as its source names it: wardrik://local/agents/acme/triage.
const agentOf = (event: WardrikEvent): string => event.source.replace(/^.*?\/agents\//, "");

const keep = (event: WardrikEvent, cursor: string, data: object = event.data) => {
  db.exec("BEGIN");
  db.prepare("INSERT OR IGNORE INTO agent_events VALUES (?, ?, ?, ?, ?)").run(
    event.id,
    agentOf(event),
    event.type,
    JSON.stringify(data),
    event.time,
  );
  save(cursor);
  db.exec("COMMIT");
};

const kept = db.prepare("SELECT cursor FROM wardrik_cursors WHERE name = 'runs'").get();
const after = typeof kept?.cursor === "string" ? kept.cursor : save(await wardrik.eventsHead({ resources }));

const stop = new AbortController();
process.on("SIGINT", () => stop.abort());

await wardrik.listen(
  {
    "wardrik.run.started": keep,
    "wardrik.run.completed": keep,
    "wardrik.run.failed": keep,
    "wardrik.events.dropped": async (event, cursor) => {
      const snapshot = await wardrik.agent(agentOf(event)).snapshot();
      keep(event, cursor, { status: snapshot.status });
    },
  },
  { resources, after, signal: stop.signal },
);
```

Make its token with `wardrik token create runs --resource 'acme/agent/*' --role reader`. `listen`
resolves once the signal aborts, and rejects with what a handler throws. It reconnects by itself
after a dropped connection.

## Show what an agent is doing

Some events are live: they show what an agent is doing as it does it, and are never kept. The rest
are kept in its log, which a listener reads on from.

| What it shows | Event | Kept |
| --- | --- | --- |
| what the agent is doing now | `wardrik.activity.changed` | no |
| its answer as it streams | `wardrik.message.delta` | no |
| its reasoning as it streams | `wardrik.reasoning.delta` | no |
| a tool's progress | `wardrik.tool_call.progress` | no |
| a model call tried again | `wardrik.message.retrying` | yes |
| each step of a turn | `wardrik.step.*` | yes |
| each tool call | `wardrik.tool_call.*` | yes |
| each agent it asks | `wardrik.subagent.*` | yes |
| each run | `wardrik.run.*` | yes |

In Elixir, subscribe to `wardrik.activity.changed`, as the embed guide's
[`subscribe/2`](/build/embed/#6-define-an-agent-and-ask-it) does, and word the activity in the
agent's snapshot with a `Wardrik.Agent.Activity.Presenter`:

```elixir title="lib/my_app/agents.ex"
def doing(user, agent) do
  with {:ok, snapshot} <- Wardrik.agent_read(scope(user), agent) do
    {:ok, Wardrik.Agent.Activity.Presenter.label(%Wardrik.Agent.Activity.English{}, snapshot.status.activity)}
  end
end
```

In TypeScript, render the event's `data.activity`:

```ts
for await (const event of wardrik.agent("acme/triage").events()) {
  if (event.type === "wardrik.activity.changed") {
    console.log(event.data.activity.doing.map((doing) => doing.type).join(", ") || "idle");
  }
}
```

An agent's activity changes many times a second while it streams. Show it at most once every two
seconds, and show a change that came in between as those two seconds end.

## Details

- **At least once.** An event whose `handle/2` was cut short comes again after a restart. Drop the
  repeat by its CloudEvent `id`, as the primary key above does.
- **A failing handler.** One that raises, or answers anything but `:ok`, restarts the listener, which
  reads on from `cursor/1`. One that always raises restarts it until its supervisor gives up.
- **The first start.** Without a saved cursor, `cursor/1` answers its `:after` option, `:head`
  unless set: what is written next. Save `Wardrik.events_head!/2` at once, as above, so a restart
  before the first event misses nothing.
- **In development**, keep the cursor in an ETS table your application owns, created as it starts:
  a crash carries on, and a restart begins from what is written next.

  ```elixir
  def handle(entry, listener) do
    IO.inspect(entry.event["type"], label: to_string(entry.log))
    true = :ets.insert(:wardrik_cursor, {:runs, listener.cursor})
    :ok
  end

  def cursor(listener) do
    case :ets.lookup(:wardrik_cursor, :runs) do
      [{:runs, cursor}] -> cursor
      [] -> listener.cursor
    end
  end
  ```

- **In a cluster**, a listener runs where you start it, and follows every event from each node that
  starts it. Start it on one node, or keep a cursor for each node, as `"runs@#{node()}"`, and let
  the unique `id` drop the repeats. [Notices](/build/notices/) run once in the cluster, under a
  `DurableServer`.
- **Cursor size.** A cursor names every agent it has read, at about 50 bytes each.
- `Wardrik.Listener` lists every option, and [Events](/reference/events/) every event.
