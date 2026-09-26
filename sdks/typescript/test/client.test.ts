import assert from "node:assert/strict";
import { beforeEach, describe, test } from "node:test";
import { Wardrik, WardrikError, type WardrikEvent } from "../src/index.ts";
import { error, event, fake, json, stream, type Fake } from "./server.ts";

let server: Fake;
let wardrik: Wardrik;

const key = "acme/_/triage";
const path = "/v1/agents/acme/_/triage";
const snapshot = (sequence: number) => ({ sequence });

beforeEach(async () => {
  server = await fake();
  wardrik = new Wardrik({ url: server.url, token: "wardrik_secret" });
});

const collect = async (events: AsyncIterable<WardrikEvent>, count = Infinity) => {
  const seen: WardrikEvent[] = [];
  for await (const event of events) {
    seen.push(event);
    if (seen.length >= count) break;
  }
  return seen;
};

describe("requests", () => {
  test("carry the token, and each segment of a key encoded on its own", async () => {
    server.on("GET", "/v1/agents/acme/a%20b/tri%3Fage", (_request, response) =>
      json(response, 200, snapshot(3)),
    );

    assert.equal((await wardrik.agent("acme/a b/tri?age").snapshot()).sequence, 3);
    assert.equal(server.received[0]!.headers.authorization, "Bearer wardrik_secret");
    await server.close();
  });

  test("refuse a key that is not three segments", async () => {
    assert.throws(() => wardrik.agent("acme/triage"), TypeError);
    assert.throws(() => wardrik.agent("acme//triage"), TypeError);
    await server.close();
  });

  test("throw what the server answers as an error", async () => {
    server.on("GET", path, (_request, response) =>
      json(response, 404, error("not_found", "No agent runs under acme/_/triage.")),
    );

    await assert.rejects(wardrik.agent(key).snapshot(), (thrown: unknown) => {
      assert.ok(thrown instanceof WardrikError);
      assert.equal(thrown.status, 404);
      assert.equal(thrown.type, "not_found");
      assert.equal(thrown.message, "No agent runs under acme/_/triage.");
      assert.equal(thrown.requestId, "req_test");
      return true;
    });

    await server.close();
  });

  test("need a token", async () => {
    const previous = process.env.WARDRIK_TOKEN;
    delete process.env.WARDRIK_TOKEN;
    assert.throws(() => new Wardrik({ url: server.url }), TypeError);

    process.env.WARDRIK_TOKEN = "wardrik_env";
    assert.doesNotThrow(() => new Wardrik({ url: server.url }));

    if (previous === undefined) delete process.env.WARDRIK_TOKEN;
    else process.env.WARDRIK_TOKEN = previous;
    await server.close();
  });

  test("put an agent, and answer a handle to it", async () => {
    server.on("PUT", path, (_request, response) => json(response, 201, snapshot(0)));

    const agent = await wardrik.agents.put(key, { model: "anthropic:claude-sonnet-5" });

    assert.equal(agent.key, key);
    assert.deepEqual(server.received[0]!.body, { model: "anthropic:claude-sonnet-5" });
    await server.close();
  });

  test("send a message, schedule, decide, cancel and page as the API takes them", async () => {
    server.on("POST", path + "/messages", (_request, response) =>
      json(response, 202, { message: { id: "m1" } }),
    );
    server.on("PUT", path + "/schedules/sweep", (request, response) =>
      json(response, 201, { schedule: { name: "sweep", ...(request.body as object) } }),
    );
    server.on("POST", path + "/interrupts/call_1", (_request, response) =>
      json(response, 200, { interrupt: { id: "call_1", decision: "approved" } }),
    );
    server.on("POST", path + "/cancel", (_request, response) => json(response, 202, {}));
    server.on("GET", path + "/events", (_request, response) =>
      json(response, 200, { events: [event("run.started", {}, { sequence: 5 })] }),
    );

    const agent = wardrik.agent(key);

    assert.deepEqual(await agent.send("hi", { id: "m1" }), { id: "m1" });
    await agent.schedule("sweep", { every: "*/30 * * * *", prompt: "Look." });
    await agent.approve("call_1");
    await agent.reject("call_1", "Not now.");
    await agent.cancel();
    const page = await agent.page({ after: 4, limit: 10 });

    assert.equal(page[0]!.sequence, "000000000005");
    assert.deepEqual(
      server.received.map((request) => [request.method, request.path, request.body]),
      [
        ["POST", path + "/messages", { id: "m1", parts: [{ type: "text", content: "hi" }] }],
        ["PUT", path + "/schedules/sweep", { every: "*/30 * * * *", prompt: "Look." }],
        ["POST", path + "/interrupts/call_1", { decision: "approve" }],
        ["POST", path + "/interrupts/call_1", { decision: "reject", reason: "Not now." }],
        ["POST", path + "/cancel", undefined],
        ["GET", path + "/events?starting_after=4&limit=10", undefined],
      ],
    );

    await server.close();
  });
});

describe("events", () => {
  test("follow the log from the head, and resume after the last durable event", async () => {
    server.on("GET", path, (_request, response) => json(response, 200, snapshot(7)));
    server.on(
      "GET",
      path + "/events",
      stream([event("run.started", {}, { sequence: 8 }), event("message.delta", { delta: "a" })]),
    );
    server.on("GET", path + "/events", stream([event("run.completed", {}, { sequence: 9 })], { end: false }));

    const events = wardrik.agent(key).events();
    const seen = await collect(events, 3);

    assert.deepEqual(
      seen.map((event) => event.type),
      ["wardrik.run.started", "wardrik.message.delta", "wardrik.run.completed"],
    );

    const cursors = server.received
      .filter((request) => request.path.endsWith("/events"))
      .map((request) => request.headers["last-event-id"]);

    assert.deepEqual(cursors, ["7", "8"]);
    assert.equal(events.sequence, 9);
    await server.close();
  });

  test("tell of a gap in the log", async () => {
    server.on("GET", path + "/events", (_request, response) =>
      json(response, 410, error("gap", "Events before 3 have been dropped.", { oldest: 3 })),
    );

    await assert.rejects(collect(wardrik.agent(key).events({ after: 0 })), (thrown: unknown) => {
      assert.ok(thrown instanceof WardrikError);
      assert.equal(thrown.type, "gap");
      assert.equal(thrown.oldest, 3);
      return true;
    });

    await server.close();
  });

  test("end when their signal aborts", async () => {
    server.on("GET", path + "/events", stream([], { end: false }));
    const stop = new AbortController();
    const events = wardrik.agent(key).events({ after: 0, signal: stop.signal });

    const done = collect(events);
    await events.opened;
    stop.abort();

    assert.deepEqual(await done, []);
    await server.close();
  });
});

describe("ask", () => {
  const mine = "b".repeat(32);
  const theirs = "c".repeat(32);

  test("opens the stream before it sends, and gives only its own run's events, to its end", async () => {
    server.on("GET", path, (_request, response) => json(response, 200, snapshot(1)));
    server.on("GET", path + "/events", (request, response) => {
      stream(
        [
          event("run.started", { run: { id: theirs, message_ids: ["other"] } }, { sequence: 2, run: theirs }),
          event("message.created", { message: { id: "m1", role: "user", parts: [] } }, { sequence: 3, run: theirs }),
          event("message.delta", { message: { id: "x" }, delta: "not mine" }, { run: theirs }),
          event("run.completed", { run: { id: theirs } }, { sequence: 4, run: theirs }),
          event("run.started", { run: { id: mine, message_ids: ["m1"] } }, { sequence: 5, run: mine }),
          event("run.interrupted", { run: { id: mine }, interrupts: [] }, { sequence: 6, run: mine }),
          event("agent.started", { agent: { id: key } }, { sequence: 7, run: "d".repeat(32) }),
          event("run.resumed", { run: { id: mine } }, { sequence: 8, run: mine }),
          event("message.delta", { message: { id: "y" }, delta: "mine" }, { run: mine }),
          event("run.completed", { run: { id: mine } }, { sequence: 9, run: mine }),
          event("run.started", { run: { id: theirs, message_ids: ["later"] } }, { sequence: 10, run: theirs }),
        ],
        { end: false },
      )(request, response);
    });
    server.on("POST", path + "/messages", (_request, response) =>
      json(response, 202, { message: { id: "m1" } }),
    );

    const seen = await collect(wardrik.agent(key).ask("hi", { id: "m1" }));

    assert.deepEqual(
      server.received.map((request) => `${request.method} ${request.path}`),
      [`GET ${path}`, `GET ${path}/events`, `POST ${path}/messages`],
    );

    assert.deepEqual(
      seen.map((event) => event.type),
      [
        "wardrik.message.created",
        "wardrik.run.started",
        "wardrik.run.interrupted",
        "wardrik.agent.started",
        "wardrik.run.resumed",
        "wardrik.message.delta",
        "wardrik.run.completed",
      ],
    );

    await server.close();
  });

  test("closes its stream when the message is refused", async () => {
    server.on("GET", path, (_request, response) => json(response, 200, snapshot(1)));
    server.on("GET", path + "/events", stream([], { end: false }));
    server.on("POST", path + "/messages", (_request, response) =>
      json(response, 400, error("invalid_request", "A message has text to send")),
    );

    await assert.rejects(collect(wardrik.agent(key).ask("")), WardrikError);
    await server.close();
  });
});
