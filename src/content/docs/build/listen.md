---
title: Listen for events
description: "Process agent events with wardrik.listen, resume from a cursor, and show live activity."
sidebar:
  order: 4.6
---

`wardrik.listen` calls your handler with each event and the cursor after it. Save the cursor in
the same transaction, and a restart resumes from it.

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

## Show what an agent is doing

Some events are live only. They're streamed, but not stored.

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

Activity changes many times a second, so render it at most every two seconds.

## Details

- `wardrik.events.dropped` means the log was trimmed past your cursor. It's sent regardless of
  `:types`.
- A cursor grows by about 50 bytes per agent it has read.
- [Events](/reference/events/) lists every event.
