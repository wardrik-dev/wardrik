import type { StandardSchemaWithJSON } from "@modelcontextprotocol/server";
import { Agent } from "./agent.ts";
import { agentPath, Http } from "./http.ts";
import type { AgentDefinition, AgentSummary } from "./protocol.ts";
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

  readonly #http: Http;
  readonly #worker: Worker;

  constructor(options: WardrikOptions = {}) {
    const token = options.token ?? env("WARDRIK_TOKEN");
    if (!token) throw new TypeError("Wardrik needs a token: pass token, or set WARDRIK_TOKEN");

    const url = options.url ?? env("WARDRIK_URL") ?? "http://127.0.0.1:4747";
    this.#http = new Http(url, token, options.fetch ?? globalThis.fetch);
    this.#worker = new Worker(options.name ?? "wardrik-sdk", version);
    this.agents = new Agents(this.#http);
  }

  /** The agent under `key`, `org/name` or `org/@user/name`. */
  agent(key: string): Agent {
    return new Agent(this.#http, key);
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

/** The agents a token reaches. */
export class Agents {
  readonly #http: Http;

  constructor(http: Http) {
    this.#http = http;
  }

  /** Every agent the token reaches. */
  async list(): Promise<AgentSummary[]> {
    const answer = await this.#http.json<{ agents: AgentSummary[] }>("GET", "/v1/agents");
    return answer.agents;
  }

  /**
   * Starts the agent `definition` describes under `key`, or brings the one
   * running to it, its schedules to those `definition.schedule` lists.
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
