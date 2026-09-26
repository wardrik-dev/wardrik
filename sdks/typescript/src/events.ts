import { setTimeout as sleep } from "node:timers/promises";
import { WardrikError } from "./errors.ts";
import type { Http } from "./http.ts";
import type { WardrikEvent } from "./protocol.ts";
import { messages } from "./sse.ts";

export interface FollowOptions {
  /**
   * The sequence to follow the log after. Left out, the stream starts after
   * the last event the agent had written when it opens.
   */
  after?: number | undefined;
  signal?: AbortSignal | undefined;
}

const firstDelay = 250;
const lastDelay = 10_000;

/**
 * An agent's events as they are written, from a sequence on: an async
 * iterable that reconnects after any drop, a `kill -9` of the node included,
 * and resumes after the last durable event it saw.
 *
 * Live events, text and reasoning as it streams and tool progress, carry no
 * sequence, and a reconnect does not send again what was missed of them; the
 * `wardrik.message.completed` that follows has the whole text.
 *
 * It ends when its signal aborts. It throws a `WardrikError` of type `gap` when
 * the log no longer holds what comes after the cursor: read the agent's
 * snapshot, and follow from its sequence.
 */
export class EventStream implements AsyncIterable<WardrikEvent> {
  /** Settles once the stream is first open, or fails to open. */
  readonly opened: Promise<void>;

  readonly #http: Http;
  readonly #path: string;
  readonly #head: () => Promise<number>;
  readonly #signal: AbortSignal | undefined;
  #after: number | undefined;
  #open!: () => void;
  #fail!: (error: unknown) => void;

  constructor(http: Http, path: string, head: () => Promise<number>, options: FollowOptions = {}) {
    this.#http = http;
    this.#path = path;
    this.#head = head;
    this.#signal = options.signal;
    this.#after = options.after;

    this.opened = new Promise((resolve, reject) => {
      this.#open = resolve;
      this.#fail = reject;
    });
    this.opened.catch(() => {});
  }

  /** The sequence of the last durable event this stream has given. */
  get sequence(): number | undefined {
    return this.#after;
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<WardrikEvent> {
    const stop = new AbortController();
    const signal = this.#signal ? AbortSignal.any([this.#signal, stop.signal]) : stop.signal;
    let delay = firstDelay;

    try {
      this.#after ??= await this.#head();

      while (!signal.aborted) {
        let response: Response;

        try {
          response = await this.#http.send("GET", this.#path + "/events", {
            headers: { accept: "text/event-stream", "last-event-id": String(this.#after) },
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
            if (message.id !== undefined) this.#after = Number(message.id);
            yield event;
          }
        } catch (error) {
          if (signal.aborted) return;
          if (error instanceof SyntaxError) throw error;
        }

        await sleep(delay, undefined, { signal }).catch(() => {});
      }
    } catch (error) {
      this.#fail(error);
      throw error;
    } finally {
      stop.abort();
    }
  }
}
