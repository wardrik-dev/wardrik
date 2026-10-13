import type { StandardSchemaWithJSON } from "@modelcontextprotocol/server";
import { Agent } from "./agent.ts";
import { Connections } from "./connections.ts";
import { Deployment } from "./deployment.ts";
import { Export } from "./export.ts";
import { agentPath, Http } from "./http.ts";
import type { AgentDefinition, AgentSummary, Interrupt } from "./protocol.ts";
import { Worker, type ToolDefinition, type WorkOptions } from "./worker.ts";

export const version = "0.0.0";

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
 *     const wardrik = new Wardrik();
 *     const agent = await wardrik.agents.put("acme/triage", { model: "anthropic:claude-sonnet-5" });
 *
 *     for await (const event of agent.ask("What's on fire?")) {
 *       if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);
 *     }
 */
export class Wardrik {
  readonly agents: Agents;
  /** The accounts the token's person, or their org, connects. */
  readonly connections: Connections;
  /** The deployment itself, for a token over every agent. */
  readonly deployment: Deployment;

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
  }

  /** The agent under `key`, `org/name` or `org/@user/name`. */
  agent(key: string): Agent {
    return new Agent(this.#http, key);
  }

  /** The export under `name`: a cursor of this token's own over every log it may read. */
  export(name: string): Export {
    return new Export(this.#http, name);
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

/** What a removal under a prefix did. */
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

  constructor(http: Http) {
    this.#http = http;
  }

  /** The agents under `prefix`, such as `"acme/"`, or every one the token reaches. */
  async list(prefix?: string): Promise<AgentSummary[]> {
    const answer = await this.#http.json<{ agents: AgentSummary[] }>("GET", "/v1/agents", {
      query: { prefix },
    });

    return answer.agents;
  }

  /**
   * Stops what every agent under `prefix` is doing, where it is taking a
   * turn, and answers the keys of those it stopped. `""` is every agent.
   */
  async cancel(prefix: string): Promise<string[]> {
    const answer = await this.#http.json<{ cancelled: string[] }>("POST", "/v1/agents/cancel", {
      query: { prefix },
    });

    return answer.cancelled;
  }

  /**
   * Removes every agent under `prefix` but those the server keeps, such as one
   * an agent file declares: those removed, those kept and why, and those that
   * could not be removed and why.
   */
  async remove(prefix: string): Promise<Removal> {
    return this.#http.json<Removal>("DELETE", "/v1/agents", { query: { prefix } });
  }

  /** The calls agents under `prefix`, or every one the token reaches, wait on a person for. */
  async parked(prefix?: string): Promise<Parked[]> {
    const answer = await this.#http.json<{ interrupts: Parked[] }>("GET", "/v1/interrupts", {
      query: { prefix },
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
