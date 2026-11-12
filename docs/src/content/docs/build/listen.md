---
title: Listen for events
description: "Process agent events with wardrik.listen, resume from a cursor, and show live activity."
sidebar:
  order: 4.6
---

Use `wardrik.listen` to process events and save your position. Each handler receives an event
and its cursor. Save the event and cursor in one database transaction, then pass the saved cursor
as `after` when your app restarts.

This example assumes a configured SDK client, database helpers, and an abort signal:

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

- `listen` runs handlers one at a time and reconnects automatically. It resolves when `signal`
  aborts.
- Delivery is at least once. Key rows by `event.id` to skip duplicates.

## Display live activity

Reply deltas, progress, and activity updates are streamed live and are not stored for replay.

| Shows | Event | Stored |
| --- | --- | --- |
| what it's doing now | `wardrik.activity.changed` | no |
| its reply as it streams | `wardrik.message.delta` | no |
| a tool's progress | `wardrik.tool_call.progress` | no |
| each step, tool call and run | `wardrik.step.*`, `wardrik.tool_call.*`, `wardrik.run.*` | yes |

```ts
for await (const event of agent.streamEvents({ types: ["wardrik.activity.changed"] })) {
  console.log(event.data.activity.doing.map((doing) => doing.type).join(", ") || "idle");
}
```

Activity can change many times per second. Throttle UI updates to keep them readable.

## Details

- `wardrik.events.dropped` means the log was trimmed past your cursor. It's sent regardless of
  `:types`.
- A cursor grows by about 50 bytes per agent it has read.
- [Events](/reference/events/) lists every event.
