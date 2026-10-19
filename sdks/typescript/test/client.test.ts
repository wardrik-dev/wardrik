import assert from "node:assert/strict";
import { beforeEach, describe, test } from "node:test";
import { Wardrik, WardrikError, type WardrikEvent } from "../src/index.ts";
import { error, event, fake, json, stream, type Fake } from "./server.ts";

let server: Fake;
let wardrik: Wardrik;

const key = "acme/triage";
const path = "/v1/agents/acme/triage";
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
    server.on("GET", "/v1/agents/acme/tri%3Fage", (_request, response) =>
      json(response, 200, snapshot(3)),
    );

    assert.equal((await wardrik.agent("acme/tri?age").snapshot()).sequence, 3);
    assert.equal(server.received[0]!.headers.authorization, "Bearer wardrik_secret");
    await server.close();
  });

  test("reach a user's agent under @user, with the @ kept", async () => {
    server.on("GET", "/v1/agents/acme/@j%20n/triage", (_request, response) =>
      json(response, 200, snapshot(4)),
    );

    assert.equal((await wardrik.agent("acme/@j n/triage").snapshot()).sequence, 4);
    await server.close();
  });

  test("refuse what is not a key", async () => {
    for (const key of ["triage", "acme/jon/triage", "acme//triage", "acme/@/triage", "a/@b/c/d"]) {
      assert.throws(() => wardrik.agent(key), TypeError, key);
    }

    await server.close();
  });

  test("throw what the server answers as an error", async () => {
    server.on("GET", path, (_request, response) =>
      json(response, 404, error("not_found", "No agent runs under acme/triage.")),
    );

    await assert.rejects(wardrik.agent(key).snapshot(), (thrown: unknown) => {
      assert.ok(thrown instanceof WardrikError);
      assert.equal(thrown.status, 404);
      assert.equal(thrown.type, "not_found");
      assert.equal(thrown.message, "No agent runs under acme/triage.");
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

  test("list, cancel, remove and read the parked calls of agents under a prefix", async () => {
    server.on("GET", "/v1/agents", (_request, response) => json(response, 200, { agents: [] }));
    server.on("POST", "/v1/agents/cancel", (_request, response) =>
      json(response, 202, { cancelled: ["acme/a"] }),
    );
    server.on("DELETE", "/v1/agents", (_request, response) =>
      json(response, 200, { forgotten: ["acme/a"], kept: [], failed: [] }),
    );
    server.on("GET", "/v1/interrupts", (_request, response) =>
      json(response, 200, { interrupts: [] }),
    );

    assert.deepEqual(await wardrik.agents.list("acme/"), []);
    assert.deepEqual(await wardrik.agents.cancel("acme/"), ["acme/a"]);
    assert.deepEqual((await wardrik.agents.remove("acme/")).forgotten, ["acme/a"]);
    assert.deepEqual(await wardrik.agents.parked(), []);

    assert.deepEqual(
      server.received.map((request) => [request.method, request.path]),
      [
        ["GET", "/v1/agents?prefix=acme%2F"],
        ["POST", "/v1/agents/cancel?prefix=acme%2F"],
        ["DELETE", "/v1/agents?prefix=acme%2F"],
        ["GET", "/v1/interrupts"],
      ],
    );

    await server.close();
  });

  test("spawn, stop and move an agent as the API takes them", async () => {
    server.on("POST", path + "/spawn", (_request, response) => json(response, 200, {}));
    server.on("POST", path + "/stop", (_request, response) => json(response, 200, {}));
    server.on("POST", path + "/move", (_request, response) => json(response, 200, {}));

    const agent = wardrik.agent(key);
    await agent.spawn();
    await agent.spawn("wardrik@box2");
    await agent.stop();
    await agent.move("wardrik@box2");

    assert.deepEqual(
      server.received.map((request) => [request.method, request.path, request.body]),
      [
        ["POST", path + "/spawn", {}],
        ["POST", path + "/spawn", { node: "wardrik@box2" }],
        ["POST", path + "/stop", undefined],
        ["POST", path + "/move", { node: "wardrik@box2" }],
      ],
    );

    await server.close();
  });

  test("send a message, set a trigger, decide, cancel, clear and page as the API takes them", async () => {
    server.on("POST", path + "/messages", (_request, response) =>
      json(response, 202, { message: { id: "m1" } }),
    );
    server.on("PUT", path + "/triggers/sweep", (request, response) =>
      json(response, 201, { trigger: { name: "sweep", ...(request.body as object) } }),
    );
    server.on("POST", path + "/decisions", (_request, response) =>
      json(response, 200, { decisions: [{ id: "call_1", decision: "approved" }] }),
    );
    server.on("POST", path + "/cancel", (_request, response) => json(response, 202, {}));
    server.on("DELETE", path + "/conversation", (_request, response) => json(response, 204));
    server.on("GET", path + "/events", (_request, response) =>
      json(response, 200, { events: [event("run.started", {}, { sequence: 5 })] }),
    );

    const agent = wardrik.agent(key);

    assert.deepEqual(await agent.send("hi", { id: "m1" }), { id: "m1" });
    await agent.setTrigger("sweep", { every: "*/30 * * * *", prompt: "Look." });
    await agent.approve("call_1");
    await agent.reject("call_1", "Not now.");
    await agent.cancel();
    await agent.clear();
    const page = await agent.page({ after: 4, limit: 10 });

    assert.equal(page[0]!.sequence, "000000000005");
    assert.deepEqual(
      server.received.map((request) => [request.method, request.path, request.body]),
      [
        ["POST", path + "/messages", { id: "m1", parts: [{ type: "text", content: "hi" }] }],
        ["PUT", path + "/triggers/sweep", { every: "*/30 * * * *", prompt: "Look." }],
        ["POST", path + "/decisions", { decisions: [{ id: "call_1", decision: "approve" }] }],
        [
          "POST",
          path + "/decisions",
          { decisions: [{ id: "call_1", decision: "reject", reason: "Not now." }] },
        ],
        ["POST", path + "/cancel", undefined],
        ["DELETE", path + "/conversation", undefined],
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

describe("exports", () => {
  test("read a page, move past it, and start over", async () => {
    const started = event("wardrik.agent.started", {}, { sequence: 1 });
    const page = { events: [started], next: "e30", gaps: [] };
    server.on("GET", "/v1/exports/siem", (_request, response) => json(response, 200, page));
    server.on("POST", "/v1/exports/siem", (_request, response) => json(response, 204));
    server.on("DELETE", "/v1/exports/siem", (_request, response) => json(response, 204));

    const siem = wardrik.export("siem");
    assert.deepEqual(await siem.read({ limit: 500 }), page);
    await siem.advance(page.next);
    await siem.delete();

    assert.deepEqual(
      server.received.map((request) => [request.method, request.path, request.body]),
      [
        ["GET", "/v1/exports/siem?limit=500", undefined],
        ["POST", "/v1/exports/siem", { next: "e30" }],
        ["DELETE", "/v1/exports/siem", undefined],
      ],
    );

    await server.close();
  });
});

describe("connections", () => {
  test("list, connect and forget, for the owner named", async () => {
    const list = { connections: [{ provider: "github", held_by: "person" }, { provider: "linear" }] };
    const link = { provider: "linear", connected: false, authorization: { url: "https://auth.example.com/a" } };
    server.on("GET", "/v1/connections", (_request, response) => json(response, 200, list));
    server.on("POST", "/v1/connections/linear", (_request, response) => json(response, 200, link));
    server.on("DELETE", "/v1/connections/linear", (_request, response) => json(response, 204));

    assert.deepEqual(await wardrik.connections.list("acme/@jon"), list);
    assert.deepEqual(await wardrik.connections.connect("acme/@jon", "linear"), link);
    await wardrik.connections.disconnect("acme", "linear");

    assert.deepEqual(
      server.received.map((request) => [request.method, request.path]),
      [
        ["GET", "/v1/connections?owner=acme%2F%40jon"],
        ["POST", "/v1/connections/linear?owner=acme%2F%40jon"],
        ["DELETE", "/v1/connections/linear?owner=acme"],
      ],
    );

    await server.close();
  });
});
describe("servers", () => {
  test("list, add and remove, for the owner named", async () => {
    const list = { servers: [{ name: "crm", url: "https://mcp.crm.example/mcp", auth: "secret" as const }] };
    const added = { server: "crm", connected: true };
    server.on("GET", "/v1/servers", (_request, response) => json(response, 200, list));
    server.on("POST", "/v1/servers", (_request, response) => json(response, 201, added));
    server.on("DELETE", "/v1/servers/crm", (_request, response) => json(response, 204));

    const crm = { name: "crm", url: "https://mcp.crm.example/mcp", auth: { secret: { name: "crm-key" } } };
    assert.deepEqual(await wardrik.servers.list("acme/@jon"), list);
    assert.deepEqual(await wardrik.servers.add("acme", crm), added);
    await wardrik.servers.remove("acme/@jon", "crm");

    assert.deepEqual(
      server.received.map((request) => [request.method, request.path]),
      [
        ["GET", "/v1/servers?owner=acme%2F%40jon"],
        ["POST", "/v1/servers?owner=acme"],
        ["DELETE", "/v1/servers/crm?owner=acme%2F%40jon"],
      ],
    );
    assert.deepEqual(server.received[1]!.body, crm);

    await server.close();
  });
});


describe("tokens", () => {
  test("list, create and revoke as the API takes them", async () => {
    const token = {
      id: "0123456789ab",
      name: "ci",
      principal: { type: "user", id: "jon" },
      statements: [{ actions: ["agent.read"], resources: ["acme/"] }],
      policy: "careful",
      created_at: "2026-10-18T00:00:00Z",
    };
    server.on("GET", "/v1/tokens", (_request, response) => json(response, 200, { tokens: [token] }));
    server.on("POST", "/v1/tokens", (_request, response) =>
      json(response, 201, { token, secret: "wardrik_new" }),
    );
    server.on("DELETE", "/v1/tokens/0123456789ab", (_request, response) => json(response, 200, { token }));

    assert.deepEqual(await wardrik.tokens.list(), { tokens: [token] });

    assert.deepEqual(
      await wardrik.tokens.create({
        name: "ci",
        scope: "acme/",
        roles: ["reader"],
        policy: "careful",
        expiresIn: 3600,
      }),
      { token, secret: "wardrik_new" },
    );

    assert.deepEqual(await wardrik.tokens.revoke("0123456789ab"), token);

    assert.deepEqual(
      server.received.map((request) => [request.method, request.path, request.body]),
      [
        ["GET", "/v1/tokens", undefined],
        [
          "POST",
          "/v1/tokens",
          { name: "ci", scope: "acme/", roles: ["reader"], policy: "careful", expires_in: 3600 },
        ],
        ["DELETE", "/v1/tokens/0123456789ab", undefined],
      ],
    );

    await server.close();
  });
});

describe("deployment", () => {
  test("lists its nodes, reloads and pages the audit as the API takes them", async () => {
    const nodes = { nodes: [{ name: "wardrik@box1", agents: 2 }], asleep: 1 };
    const page = { changes: [] };
    server.on("GET", "/v1/deployment/nodes", (_request, response) => json(response, 200, nodes));
    server.on("POST", "/v1/deployment/reload", (_request, response) =>
      json(response, 200, { reloaded: ["wardrik@box1"] }),
    );
    server.on("GET", "/v1/deployment/audit", (_request, response) => json(response, 200, page));

    assert.deepEqual(await wardrik.deployment.nodes(), nodes);
    assert.deepEqual(await wardrik.deployment.reload(), ["wardrik@box1"]);
    assert.deepEqual(await wardrik.deployment.audit({ startingAfter: 120, limit: 50 }), page);

    assert.deepEqual(
      server.received.map((request) => [request.method, request.path]),
      [
        ["GET", "/v1/deployment/nodes"],
        ["POST", "/v1/deployment/reload"],
        ["GET", "/v1/deployment/audit?starting_after=120&limit=50"],
      ],
    );

    await server.close();
  });
});
