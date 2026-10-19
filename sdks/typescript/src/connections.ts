import type { Http } from "./http.ts";
import type { Connecting, Connections as ConnectionList } from "./protocol.ts";

/** What a request about connections takes beside its owner. */
export interface ConnectionOptions {
  signal?: AbortSignal;
}

/**
 * The accounts an owner's agents act with: a sign-in an agent's tools use,
 * connected before any agent asks for it. The owner is an org, `acme`, or a
 * person, `acme/@jon`.
 *
 *     const { connections } = await wardrik.connections.list("acme/@jon");
 *     const linear = await wardrik.connections.connect("acme/@jon", "linear");
 *     if (!linear.connected) console.log("Authorize at", linear.authorization?.url);
 */
export class Connections {
  readonly #http: Http;

  /** @internal */
  constructor(http: Http) {
    this.#http = http;
  }

  /** The accounts offered `owner`, and whether the person, the org or the deployment holds each. */
  list(owner: string, options: ConnectionOptions = {}): Promise<ConnectionList> {
    return this.#http.json("GET", "/v1/connections", request(owner, options));
  }

  /** Connects `owner`'s account at `provider`: where to authorize it, or that it is held already. */
  connect(owner: string, provider: string, options: ConnectionOptions = {}): Promise<Connecting> {
    return this.#http.json("POST", path(provider), request(owner, options));
  }

  /** Forgets `owner`'s account at `provider`, so the next call that needs it asks again. */
  async disconnect(owner: string, provider: string, options: ConnectionOptions = {}): Promise<void> {
    await this.#http.send("DELETE", path(provider), request(owner, options));
  }
}

const path = (provider: string): string => `/v1/connections/${encodeURIComponent(provider)}`;

const request = (owner: string, { signal }: ConnectionOptions) => ({ query: { owner }, signal });
