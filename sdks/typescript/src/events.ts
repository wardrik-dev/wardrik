import { setTimeout as sleep } from "node:timers/promises";
import { WardrikError } from "./errors.ts";
import type { Http, Request } from "./http.ts";
import type { EventsPage, WardrikEvent } from "./protocol.ts";
import { messages } from "./sse.ts";

/** Where `agent.events` starts following an agent's log. */
export interface FollowOptions {
  /**
   * The cursor to read after: an event's, a page's `next`, a message's or a
   * snapshot's. Left out, the stream starts at what is written next.
   */
  after?: string | undefined;
  signal?: AbortSignal | undefined;
}

/** Which events `wardrik.events` reads, and from where. */
export interface EventsOptions extends FollowOptions {
  /** The agents each pattern covers, as `"acme/agent/*"`; every agent the token reads where left out. */
  resources?: string[] | undefined;
  /**
   * The event types to read, as `"wardrik.run.completed"`; every type where
   * left out. A `wardrik.events.dropped` comes whatever the types.
   */
  types?: string[] | undefined;
  /**
   * Whether to go on to give each event as it is written. Left out, the
   * events kept after `after`, from the start where that is left out too,
   * a page at a time.
   */
  follow?: boolean | undefined;
}

const firstDelay = 250;
const lastDelay = 10_000;

/**
 * Agents' events, after a cursor on: an async iterable that, following,
 * reconnects after any drop, a `kill -9` of the node included, and resumes
 * after the last event it gave that moved its cursor.
 *
 * Live events, text and reasoning as it streams and tool progress, move no
 * cursor, and a reconnect does not send again what was missed of them; the
 * `wardrik.message.completed` that follows has the whole text. Where a log
 * was trimmed past the cursor, a `wardrik.events.dropped` says so, and the
 * log is read on from the oldest event it holds.
 *
 * It ends when its signal aborts, or, not following, once it has read what
 * is kept.
 */
export class EventStream implements AsyncIterable<WardrikEvent> {
  /** Settles once the stream is first open, or fails to open. */
  readonly opened: Promise<void>;

  readonly #http: Http;
  readonly #path: string;
  readonly #query: NonNullable<Request["query"]>;
  readonly #follow: boolean;
  readonly #head: () => Promise<string | undefined>;
  readonly #signal: AbortSignal | undefined;
  #after: string | undefined;
  #open!: () => void;
  #fail!: (error: unknown) => void;

  /** @internal */
  constructor(
    http: Http,
    path: string,
    options: EventsOptions = {},
    head: () => Promise<string | undefined> = async () => undefined,
  ) {
    this.#http = http;
    this.#path = path;
    this.#query = { resources: options.resources, types: options.types };
    this.#follow = options.follow ?? false;
    this.#head = head;
    this.#signal = options.signal;
    this.#after = options.after;

    this.opened = new Promise((resolve, reject) => {
      this.#open = resolve;
      this.#fail = reject;
    });
    this.opened.catch(() => {});
  }

  /** The cursor after the last event this stream has given that moved it, or a page it read. */
  get cursor(): string | undefined {
    return this.#after;
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<WardrikEvent> {
    const stop = new AbortController();
    const signal = this.#signal ? AbortSignal.any([this.#signal, stop.signal]) : stop.signal;

    try {
      yield* this.#follow ? this.#stream(signal) : this.#pages(signal);
    } catch (error) {
      this.#fail(error);
      throw error;
    } finally {
      stop.abort();
    }
  }

  async *#pages(signal: AbortSignal): AsyncGenerator<WardrikEvent> {
    for (;;) {
      const query = { ...this.#query, after: this.#after, limit: 500 };
      const page = await this.#http.json<EventsPage>("GET", this.#path, { query, signal });
      this.#open();
      yield* page.events as WardrikEvent[];
      this.#after = page.next;
      if (page.events.length === 0) return;
    }
  }

  async *#stream(signal: AbortSignal): AsyncGenerator<WardrikEvent> {
    let delay = firstDelay;
    this.#after ??= await this.#head();

    while (!signal.aborted) {
      let response: Response;
      const resume = this.#after === undefined ? {} : { "last-event-id": this.#after };

      try {
        response = await this.#http.send("GET", this.#path, {
          headers: { accept: "text/event-stream", ...resume },
          query: this.#query,
          signal,
        });
      } catch (error) {
        if (signal.aborted) return;
        if (error instanceof WardrikError && error.status < 500) throw error;
        await sleep(delay, undefined, { signal }).catch(() => {});
        delay = Math.min(delay * 2, lastDelay);
        continue;
      }

      this.#open();
      delay = firstDelay;

      try {
        for await (const message of messages(response.body!)) {
          const event = JSON.parse(message.data) as WardrikEvent;
          if (message.id !== undefined) this.#after = message.id;
          yield event;
        }
      } catch (error) {
        if (signal.aborted) return;
        if (error instanceof SyntaxError) throw error;
      }

      await sleep(delay, undefined, { signal }).catch(() => {});
    }
  }
}
