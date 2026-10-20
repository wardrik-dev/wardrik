// Keeps when each run of acme's agents starts and ends in a SQLite file, with
// the cursor past it in the same transaction, so a restart carries on where
// it stopped.
//
//   wardrik token create runs --resource 'acme/agent/*' --role reader
//   WARDRIK_TOKEN=wardrik_… node examples/runs.ts

import { DatabaseSync } from "node:sqlite";
import { Wardrik, type WardrikEvent } from "../src/index.ts";

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

// An event comes again after a restart that cut its transaction short; the
// id it is kept under drops the repeat.
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

// The first start reads from the head of every log, kept at once so a restart
// before the first event misses nothing.
const kept = db.prepare("SELECT cursor FROM wardrik_cursors WHERE name = 'runs'").get();
const after = typeof kept?.cursor === "string" ? kept.cursor : save(await wardrik.eventsHead({ resources }));

const stop = new AbortController();
process.on("SIGINT", () => stop.abort());

await wardrik.listen(
  {
    "wardrik.run.started": keep,
    "wardrik.run.completed": keep,
    "wardrik.run.failed": keep,
    // The log was trimmed past the cursor, so the events between are gone:
    // keep what the agent says of itself now in their place.
    "wardrik.events.dropped": async (event, cursor) => {
      const snapshot = await wardrik.agent(agentOf(event)).snapshot();
      keep(event, cursor, { status: snapshot.status });
    },
  },
  { resources, after, signal: stop.signal },
);
