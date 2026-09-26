import { EventStream, type FollowOptions } from "./events.ts";
import { agentPath, type Http } from "./http.ts";
import type {
  AgentDefinition,
  AgentSnapshot,
  Authorization,
  Schedule,
  ScheduleDefinition,
  WardrikEvent,
} from "./protocol.ts";

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
 * One agent, by its key, `org/user/name`. Every method is one request, and
 * nothing is read until one is called.
 */
export class Agent {
  /** The agent's key, `org/user/name`. */
  readonly key: string;

  readonly #http: Http;
  readonly #path: string;

  constructor(http: Http, key: string) {
    this.key = key;
    this.#http = http;
    this.#path = agentPath(key);
  }

  /** What the agent holds now, with `sequence`, the last event its log has written. */
  snapshot(options: { signal?: AbortSignal } = {}): Promise<AgentSnapshot> {
    return this.#http.json("GET", this.#path, options);
  }

  /** The definition last put, where the server keeps definitions. */
  definition(): Promise<AgentDefinition> {
    return this.#http.json("GET", this.#path + "/definition");
  }

  /** Queues a message for the agent's next run, and answers its id. */
  async send(content: string, options: SendOptions = {}): Promise<{ id: string }> {
    const body = {
      ...(options.id === undefined ? {} : { id: options.id }),
      parts: [{ type: "text", content }],
    };

    const answer = await this.#http.json<{ message: { id: string } }>(
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
    const done = new AbortController();
    const signal = options.signal ? AbortSignal.any([options.signal, done.signal]) : done.signal;
    const stream = this.events({ signal });
    const events = stream[Symbol.asyncIterator]();

    try {
      const first = events.next();
      first.catch(() => {});
      await stream.opened;
      await this.send(content, { id, signal: options.signal });

      let run: string | undefined;

      for (let next = await first; !next.done; next = await events.next()) {
        const event = next.value;

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
    } finally {
      done.abort();
      await events.return(undefined);
    }
  }

  /**
   * The agent's events as they are written, after `after`, or after the last
   * one written when it opens. See `EventStream`.
   */
  events(options: FollowOptions = {}): EventStream {
    const head = async () => (await this.snapshot()).sequence;
    return new EventStream(this.#http, this.#path, head, options);
  }

  /** A page of the agent's log: up to `limit` durable events after `after`. */
  async page(options: { after?: number; limit?: number } = {}): Promise<WardrikEvent[]> {
    const query = { starting_after: options.after ?? 0, limit: options.limit };
    const page = await this.#http.json<{ events: WardrikEvent[] }>("GET", this.#path + "/events", {
      query,
    });

    return page.events;
  }

  /** Approves a call the agent is waiting on. */
  async approve(interrupt: string): Promise<void> {
    await this.#decide(interrupt, { decision: "approve" });
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
    await this.#decide(interrupt, { decision: "reject", ...(reason ? { reason } : {}) });
  }

  /** Stops what the agent is doing. */
  async cancel(): Promise<void> {
    await this.#http.send("POST", this.#path + "/cancel");
  }

  /** Asks the agent on a clock, as `name`, replacing a schedule of that name. */
  async schedule(name: string, definition: ScheduleDefinition): Promise<Schedule> {
    const answer = await this.#http.json<{ schedule: Schedule }>(
      "PUT",
      this.#path + "/schedules/" + encodeURIComponent(name),
      { body: definition },
    );

    return answer.schedule;
  }

  /** Stops the schedule `name` and deletes it. */
  async unschedule(name: string): Promise<void> {
    await this.#http.send("DELETE", this.#path + "/schedules/" + encodeURIComponent(name));
  }

  /** Stops the agent and deletes everything it had. */
  async delete(): Promise<void> {
    await this.#http.send("DELETE", this.#path);
  }

  async #decide(interrupt: string, body: object): Promise<void> {
    await this.#http.send("POST", this.#path + "/interrupts/" + encodeURIComponent(interrupt), {
      body,
    });
  }
}
