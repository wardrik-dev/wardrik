import type { StandardSchemaWithJSON } from "@modelcontextprotocol/server";
import { Agent } from "./agent.ts";
import { Connections } from "./connections.ts";
import { Servers } from "./servers.ts";
import { Deployment } from "./deployment.ts";
import { EventStream, type EventsOptions } from "./events.ts";
import { Tokens } from "./tokens.ts";
import { agentPath, Http } from "./http.ts";
import type { AgentDefinition, AgentSummary, Interrupt } from "./protocol.ts";
import { Worker, type ToolDefinition, type WorkOptions } from "./worker.ts";

/** This SDK's version. */
export const version = "0.0.0";

/** How `new Wardrik()` reaches the server. Each is optional. */
export interface WardrikOptions {
  /** The server. `WARDRIK_URL`, else `http://127.0.0.1:4747`, the daemon's own. */
  url?: string;
  /** A token from `wardrik token create`. `WARDRIK_TOKEN` where left out. */
  token?: string;
  /** What requests are made with; the global `fetch` where left out. */
  fetch?: typeof fetch;
  /** What this process calls itself as a tool worker. */
  name?: string;
}

const env = (name: string): string | undefined =>
  (globalThis as { process?: { env: Record<string, string | undefined> } }).process?.env[name];

/**
 * A Wardrik server, as one token reaches it.
 *
 * ```ts
 * const wardrik = new Wardrik();
 * const agent = await wardrik.agents.put("acme/triage", { model: "anthropic:claude-sonnet-5" });
 *
 * for await (const event of agent.ask("What's on fire?")) {
 *   if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);
 * }
 * ```
 */
export class Wardrik {
  readonly agents: Agents;
  /** The accounts an owner's agents act with. */
  readonly connections: Connections;
  /** The deployment itself, for a token owning every agent. */
  readonly deployment: Deployment;
  /** The MCP servers an owner adds for their own agents. */
  readonly servers: Servers;
  /** The API's tokens, for a token owning every agent. */
  readonly tokens: Tokens;

  readonly #http: Http;
  readonly #worker: Worker;

  constructor(options: WardrikOptions = {}) {
    const token = options.token ?? env("WARDRIK_TOKEN");
    if (!token) throw new TypeError("Wardrik needs a token: pass token, or set WARDRIK_TOKEN");

    const url = options.url ?? env("WARDRIK_URL") ?? "http://127.0.0.1:4747";
    this.#http = new Http(url, token, options.fetch ?? globalThis.fetch);
    this.#worker = new Worker(options.name ?? "wardrik-sdk", version);
    this.agents = new Agents(this.#http);
    this.connections = new Connections(this.#http);
    this.deployment = new Deployment(this.#http);
    this.servers = new Servers(this.#http);
    this.tokens = new Tokens(this.#http);
  }

  /** The agent under `key`, `org/name` or `org/@user/name`. */
  agent(key: string): Agent {
    return new Agent(this.#http, key);
  }

  /**
   * The events of the agents `resources` covers, of `types`, after `after`:
   * those kept, or with `follow`, then each as it is written. The server keeps
   * no reader's place: keep `cursor`, and read on from it. Following with no
   * `after`, it starts from `eventsHead`, so `cursor` resumes in every agent it reads.
   *
   *     const events = wardrik.events({ resources: ["acme/agent/*"], after: saved, follow: true });
   *     for await (const event of events) save(event, events.cursor);
   */
  events(options: EventsOptions = {}): EventStream {
    return new EventStream(this.#http, "/v1/events", options, () => this.eventsHead(options));
  }

  /**
   * The cursor where the log of every agent `resources` covers stands now, or
   * of every agent the token reads: reading after it takes what is written
   * from now on, and a cursor moved from it resumes in each of them.
   */
  async eventsHead(options: Pick<EventsOptions, "resources"> = {}): Promise<string> {
    const answer = await this.#http.json<{ cursor: string }>("GET", "/v1/events/head", {
      query: { resources: options.resources },
    });

    return answer.cursor;
  }

  /**
   * Offers a tool that runs in this process to the agents the token reaches,
   * once `work` is called. An agent calls it where its definition names
   * `workers/*` among its tools.
   *
   *     wardrik.tool({
   *       name: "refund_order",
   *       description: "Refund an order in full.",
   *       input: z.object({ orderId: z.string() }),
   *       idempotent: true,
   *       run: ({ orderId }, { idempotencyKey }) =>
   *         stripe.refunds.create({ payment_intent: orderId }, { idempotencyKey }),
   *     });
   *
   *     await wardrik.work();
   */
  tool<Input extends StandardSchemaWithJSON>(definition: ToolDefinition<Input>): this {
    this.#worker.add(definition);
    return this;
  }

  /** Answers calls to the tools offered with `tool`, until `signal` aborts. */
  work(options: WorkOptions = {}): Promise<void> {
    return this.#worker.work(this.#http, options);
  }
}

/** What a removal by a pattern did. */
export interface Removal {
  forgotten: string[];
  kept: { id: string; why: string }[];
  failed: { id: string; why: string }[];
}

/** A call an agent waits on a person for, with the agent's key. */
export type Parked = Interrupt & { agent: { id: string } };

/** The agents a token reaches. */
export class Agents {
  readonly #http: Http;

  /** @internal */
  constructor(http: Http) {
    this.#http = http;
  }

  /**
   * The agents the resource pattern `resource` covers, such as `"acme/agent/*"`, or those the
   * token's one resource covers.
   */
  async list(resource?: string): Promise<AgentSummary[]> {
    const answer = await this.#http.json<{ agents: AgentSummary[] }>("GET", "/v1/agents", {
      query: { resource },
    });

    return answer.agents;
  }

  /**
   * Stops what every agent `resource` covers is doing, where it is taking a
   * turn, and answers the keys of those it stopped.
   */
  async cancel(resource: string): Promise<string[]> {
    const answer = await this.#http.json<{ cancelled: string[] }>("POST", "/v1/agents/cancel", {
      query: { resource },
    });

    return answer.cancelled;
  }

  /**
   * Removes every agent `resource` covers but those the server keeps, such as
   * one an agent file declares: those removed, those kept and why, and those
   * that could not be removed and why.
   */
  async remove(resource: string): Promise<Removal> {
    return this.#http.json<Removal>("DELETE", "/v1/agents", { query: { resource } });
  }

  /** The calls agents `resource` covers, or those the token's one resource covers, wait on a person for. */
  async parked(resource?: string): Promise<Parked[]> {
    const answer = await this.#http.json<{ interrupts: Parked[] }>("GET", "/v1/interrupts", {
      query: { resource },
    });

    return answer.interrupts;
  }

  /**
   * Starts the agent `definition` describes under `key`, or brings the one
   * running to it, its triggers to those `definition.triggers` lists.
   */
  async put(key: string, definition: AgentDefinition): Promise<Agent> {
    await this.#http.send("PUT", agentPath(key), { body: definition });
    return new Agent(this.#http, key);
  }

  /** Stops the agent under `key` and deletes everything it had. */
  async delete(key: string): Promise<void> {
    await this.#http.send("DELETE", agentPath(key));
  }
}
