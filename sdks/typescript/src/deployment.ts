import type { Http } from "./http.ts";
import type { Envelope, Nodes } from "./protocol.ts";

/** A page of the audit: what people changed, oldest first. */
export interface AuditPage {
  changes: Envelope[];
}

/** Which page of the audit log `audit` reads. */
export interface AuditOptions {
  /** The sequence number of the last change already read; the start where left out. */
  startingAfter?: number;
  /** How many changes, up to 500; 100 where left out. */
  limit?: number;
  signal?: AbortSignal;
}

/**
 * The deployment itself, for a token owning every agent: its nodes, reading
 * its definitions again, and what people changed across it. Its tokens are
 * `wardrik.tokens`.
 *
 *     const { nodes, asleep } = await wardrik.deployment.nodes();
 *     const { changes } = await wardrik.deployment.audit({ startingAfter: 120 });
 */
export class Deployment {
  readonly #http: Http;

  /** @internal */
  constructor(http: Http) {
    this.#http = http;
  }

  /** The deployment's nodes, each with how many agents run on it, and how many sleep. */
  nodes(): Promise<Nodes> {
    return this.#http.json("GET", "/v1/deployment/nodes");
  }

  /** Has every node whose host reads its definitions again do so; answers those nodes. */
  async reload(): Promise<string[]> {
    const answer = await this.#http.json<{ reloaded: string[] }>("POST", "/v1/deployment/reload");
    return answer.reloaded;
  }

  /** A page of what people changed, after `startingAfter`. */
  audit({ startingAfter, limit, signal }: AuditOptions = {}): Promise<AuditPage> {
    return this.#http.json("GET", "/v1/deployment/audit", {
      query: { starting_after: startingAfter, limit },
      signal,
    });
  }
}
