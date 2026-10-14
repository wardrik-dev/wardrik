import type { Http } from "./http.ts";
import type { Connecting, Connections as ConnectionList } from "./protocol.ts";

/** Whose connections: the token's person's own, or with `"org"` their org's. */
export interface ConnectionOptions {
  owner?: "org";
  signal?: AbortSignal;
}

/**
 * The accounts a token's person, or their org, connects: a sign-in an
 * agent's tools use, connected before any agent asks for it.
 *
 *     const { connections } = await wardrik.connections.list();
 *     const linear = await wardrik.connections.connect("linear");
 *     if (!linear.connected) console.log("Authorize at", linear.authorization?.url);
 */
export class Connections {
  readonly #http: Http;

  /** @internal */
  constructor(http: Http) {
    this.#http = http;
  }

  /** The accounts offered, and whether the person, the org or the deployment holds each. */
  list(options: ConnectionOptions = {}): Promise<ConnectionList> {
    return this.#http.json("GET", "/v1/connections", request(options));
  }

  /** Connects `provider`: where to authorize it, or that it is held already. */
  connect(provider: string, options: ConnectionOptions = {}): Promise<Connecting> {
    return this.#http.json("POST", path(provider), request(options));
  }

  /** Forgets `provider`, so the next call that needs it asks again. */
  async disconnect(provider: string, options: ConnectionOptions = {}): Promise<void> {
    await this.#http.send("DELETE", path(provider), request(options));
  }
}

const path = (provider: string): string => `/v1/connections/${encodeURIComponent(provider)}`;

const request = ({ owner, signal }: ConnectionOptions) => ({ query: { owner }, signal });
