import { EventStream, type FollowOptions } from "./events.ts";
import { agentPath, type Http } from "./http.ts";
import type {
  AgentSnapshot,
  Authorization,
  Decisions,
  DefinitionRead,
  EventsPage,
  Trigger,
  TriggerDefinition,
  WardrikEvent,
} from "./protocol.ts";

/** How `send` and `ask` send a message. */
export interface SendOptions {
  /**
   * The message's id. A message sent twice with the same id is taken once, so
   * a retry after a lost answer is safe. A new one is made where left out.
   */
  id?: string | undefined;
  signal?: AbortSignal | undefined;
}

/** An event that ends a run. */
const ends = new Set(["wardrik.run.completed", "wardrik.run.failed", "wardrik.run.cancelled"]);

/** The run an event belongs to: the trace id of its `traceparent`. */
const runOf = (event: WardrikEvent): string | undefined => event.traceparent.split("-")[1];

/**
 * One agent, by its key, `org/name` or `org/@user/name`. Every method is one
 * request, and nothing is read until one is called.
 */
export class Agent {
  /** The agent's key, `org/name` or `org/@user/name`. */
  readonly key: string;

  readonly #http: Http;
  readonly #path: string;

  /** @internal */
  constructor(http: Http, key: string) {
    this.key = key;
    this.#http = http;
    this.#path = agentPath(key);
  }

  /** What the agent holds now, with `cursor`, where its log stands. */
  snapshot(options: { signal?: AbortSignal } = {}): Promise<AgentSnapshot> {
    return this.#http.json("GET", this.#path, options);
  }

  /**
   * The definition last put, where the server keeps definitions, and the tools it names that offer
   * nothing yet, such as an MCP server its owner has not added.
   */
  definition(): Promise<DefinitionRead> {
    return this.#http.json("GET", this.#path + "/definition");
  }

  /**
   * Queues a message for the agent's next run, and answers its id, and the
   * cursor its log stood at: the run that answers it is read after it.
   */
  async send(content: string, options: SendOptions = {}): Promise<{ id: string; cursor: string }> {
    const body = {
      ...(options.id === undefined ? {} : { id: options.id }),
      parts: [{ type: "text", content }],
    };

    const answer = await this.#http.json<{ message: { id: string; cursor: string } }>(
      "POST",
      this.#path + "/messages",
      { body, signal: options.signal },
    );

    return answer.message;
  }

  /**
   * Sends a message and gives the events of the run that answers it, until
   * that run completes, fails or is cancelled. A run that is interrupted to
   * wait on a person carries on once each interrupt is resolved, with
   * `approve` or `reject`, and its events follow.
   *
   *     for await (const event of agent.ask("What's on fire?")) {
   *       if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);
   *       if (event.type === "wardrik.run.interrupted") {
   *         for (const interrupt of event.data.interrupts) await agent.approve(interrupt.id);
   *       }
   *     }
   *
   * The events of other runs are left out, and so is `wardrik.agent.started`,
   * except when the agent moves to another node during this run.
   */
  async *ask(content: string, options: SendOptions = {}): AsyncGenerator<WardrikEvent> {
    const id = options.id ?? crypto.randomUUID();
    const { cursor } = await this.send(content, { id, signal: options.signal });
    let run: string | undefined;

    for await (const event of this.events({ after: cursor, signal: options.signal })) {
      if (event.type === "wardrik.message.created" && event.data.message.id === id) {
        yield event;
      } else if (event.type === "wardrik.run.started" && event.data.run.message_ids?.includes(id)) {
        run = event.data.run.id;
        yield event;
      } else if (run !== undefined && (runOf(event) === run || event.type === "wardrik.agent.started")) {
        yield event;
        if (ends.has(event.type)) return;
      }
    }
  }

  /**
   * The agent's events as they are written, after `after`, or after where
   * its log stood when it opens. See `EventStream`.
   */
  events(options: FollowOptions = {}): EventStream {
    const head = async () => (await this.snapshot()).cursor;
    return new EventStream(this.#http, this.#path + "/events", { ...options, follow: true }, head);
  }

  /** A page of the agent's log: up to `limit` events after `after`, and `next`, the cursor after them. */
  page(options: { after?: string; limit?: number } = {}): Promise<EventsPage> {
    return this.#http.json("GET", this.#path + "/events", { query: options });
  }

  /**
   * Approves a call the agent is waiting on; the model reads `note` beside
   * the call's answer. The call runs as the model wrote it, whatever the note
   * says.
   */
  async approve(interrupt: string, note?: string): Promise<void> {
    await this.decide([{ id: interrupt, decision: "approve", ...(note ? { note } : {}) }]);
  }

  /**
   * Decides calls the agent is waiting on, taken together: each one's id,
   * `approve` with a `note`, or `reject` with a `reason`.
   */
  async decide(decisions: Decisions["decisions"]): Promise<void> {
    await this.#http.send("POST", this.#path + "/decisions", { body: { decisions } });
  }

  /**
   * Where a person authorizes a call the agent is waiting on with reason
   * `authorization`: the page to open, and the code to enter there where one
   * is needed. No event carries it, and the token must be able to decide the
   * agent's calls.
   */
  async authorization(interrupt: string): Promise<Authorization> {
    return this.#http.json<Authorization>(
      "GET",
      this.#path + "/interrupts/" + encodeURIComponent(interrupt) + "/authorization",
    );
  }

  /** Rejects a call the agent is waiting on; the model is told `reason`. */
  async reject(interrupt: string, reason?: string): Promise<void> {
    await this.decide([{ id: interrupt, decision: "reject", ...(reason ? { reason } : {}) }]);
  }

  /** Stops what the agent is doing. */
  async cancel(): Promise<void> {
    await this.#http.send("POST", this.#path + "/cancel");
  }

  /**
   * Starts the agent: wakes it, starts it on the definition the server keeps,
   * or has the server define it. On `node`, only with a token over every agent.
   */
  async spawn(node?: string): Promise<void> {
    await this.#http.send("POST", this.#path + "/spawn", { body: node ? { node } : {} });
  }

  /** Stops the agent, keeping its conversation; it wakes when something asks it. */
  async stop(): Promise<void> {
    await this.#http.send("POST", this.#path + "/stop");
  }

  /** Starts the agent again on `node`, with its conversation; a token over every agent only. */
  async move(node: string): Promise<void> {
    await this.#http.send("POST", this.#path + "/move", { body: { node } });
  }

  /**
   * Empties the agent's conversation, and with it the mark of content from
   * outside it held, which holds its gated tools' calls for a person until
   * then. Refused while the agent runs a turn or waits on a person.
   */
  async clear(): Promise<void> {
    await this.#http.send("DELETE", this.#path + "/conversation");
  }

  /** Sets the trigger `name`, replacing one of that name. */
  async setTrigger(name: string, definition: TriggerDefinition): Promise<Trigger> {
    const answer = await this.#http.json<{ trigger: Trigger }>(
      "PUT",
      this.#path + "/triggers/" + encodeURIComponent(name),
      { body: definition },
    );

    return answer.trigger;
  }

  /** Stops the trigger `name` and deletes it. */
  async removeTrigger(name: string): Promise<void> {
    await this.#http.send("DELETE", this.#path + "/triggers/" + encodeURIComponent(name));
  }

  /** Stops the agent and deletes everything it had. */
  async delete(): Promise<void> {
    await this.#http.send("DELETE", this.#path);
  }

}
