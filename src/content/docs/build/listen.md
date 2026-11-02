---
title: Follow events into your app
description: "Keep what agents do in your own tables, carry on after any restart, and show what an agent is doing as it works."
sidebar:
  order: 4.6
---

A listener hands each event to your code with the cursor past it. Save the cursor with your work,
and a restart carries on from there.

## In Elixir

```elixir title="lib/my_app/agent_runs.ex"
defmodule MyApp.AgentRuns do
  use Wardrik.Listener,
    wardrik: MyApp.AgentRuntime,
    types: ~w(wardrik.run.started wardrik.run.completed wardrik.run.failed)

  alias MyApp.Repo

  @impl true
  def handle(%Wardrik.Event{} = event, listener) do
    row = %{id: event.id, agent: event.agent, type: event.type, data: event.data, at: event.time}

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.insert_all("agent_events", [row], on_conflict: :nothing)
        MyApp.Cursors.put!("runs", listener.cursor)
      end)

    :ok
  end

  @impl true
  def cursor(_listener), do: MyApp.Cursors.get("runs")
end
```

```elixir title="config/config.exs"
config :my_app, MyApp.AgentRuntime, listeners: [MyApp.AgentRuns]
```

- `agent_events` and the cursor table are your own. Key events by `id`.
- Each event comes at least once. `on_conflict: :nothing` drops a repeat.
- `cursor/1` returning `nil` starts with events written from then on.
- A handler that raises, or returns anything but `:ok`, restarts the listener from `cursor/1`.
- `:agents` follows some agents only. `Wardrik.Listener` lists every option.

## In TypeScript

```ts
await wardrik.listen(
  {
    "wardrik.run.completed": async (event, cursor) => {
      await db.transaction(async (tx) => {
        await tx.insertRun(event.id, event.data);
        await tx.saveCursor("runs", cursor);
      });
    },
  },
  { agents: [process.env.AGENT!], after: await db.cursor("runs"), signal },
);
```

`listen` waits for each handler before the next, and reconnects by itself. It resolves once
`signal` aborts.

## Show what an agent is doing

Some events are live: shown as they happen, never kept.

| Shows | Event | Kept |
| --- | --- | --- |
| what it's doing now | `wardrik.activity.changed` | no |
| its answer as it streams | `wardrik.message.delta` | no |
| a tool's progress | `wardrik.tool_call.progress` | no |
| each step, tool call and run | `wardrik.step.*`, `wardrik.tool_call.*`, `wardrik.run.*` | yes |

```ts
for await (const event of agent.streamEvents({ types: ["wardrik.activity.changed"] })) {
  console.log(event.data.activity.doing.map((doing) => doing.type).join(", ") || "idle");
}
```

In Elixir, `Wardrik.Agent.read/2` returns the agent with its `activity`. Activity changes many
times a second: show it at most every two seconds.

## Details

- A `wardrik.events.dropped` event says the log was trimmed past your cursor. It comes whatever
  `:types` says.
- In a cluster, a listener follows every node's events where you start it. Start it on one node.
- A cursor grows about 50 bytes for each agent it has read.
- [Events](/reference/events/) lists every event.
