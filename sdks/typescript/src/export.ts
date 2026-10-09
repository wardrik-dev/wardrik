import type { Http } from "./http.ts";
import type { ExportPage } from "./protocol.ts";

/**
 * An export: a cursor of this token's own, kept on the server under its name,
 * over every log the token may read. A page leaves the cursor where it is
 * until `advance` moves it, so each event arrives at least once.
 *
 *     const siem = wardrik.export("siem");
 *     const page = await siem.read({ limit: 500 });
 *     await ship(page.events);
 *     await siem.advance(page.next);
 */
export class Export {
  /** The export's name, one segment, as an agent's name is. */
  readonly name: string;

  readonly #http: Http;
  readonly #path: string;

  constructor(http: Http, name: string) {
    this.name = name;
    this.#http = http;
    this.#path = `/v1/exports/${encodeURIComponent(name)}`;
  }

  /** The events after the cursor, which stays where it is. */
  read(options: { limit?: number; signal?: AbortSignal } = {}): Promise<ExportPage> {
    return this.#http.json("GET", this.#path, {
      query: { limit: options.limit },
      signal: options.signal,
    });
  }

  /** Moves the cursor past a page, by its `next`, once what it held is kept. */
  async advance(next: string): Promise<void> {
    await this.#http.send("POST", this.#path, { body: { next } });
  }

  /** Deletes the cursor, so the next read starts from the beginning. */
  async delete(): Promise<void> {
    await this.#http.send("DELETE", this.#path);
  }
}
