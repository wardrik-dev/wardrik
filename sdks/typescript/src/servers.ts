import type { Http } from "./http.ts";
import type { ServerAdded, Servers as ServerList } from "./protocol.ts";

/** Whose servers: the token's person's own, or with `"org"` their org's. */
export interface ServerOptions {
  owner?: "org";
  signal?: AbortSignal;
}

/** How the owner's agents sign in to a server: with nothing, in a browser, or a secret the owner keeps in the vault. */
export type ServerAuth =
  | { none: Record<string, never> }
  | { oauth: { scopes?: string[] } }
  | { secret: { name: string; header?: string; scheme?: string } };

/** A server to add: its name, its URL, how its agents sign in, and which of its tools they take. */
export interface ServerFields {
  name: string;
  url: string;
  auth: ServerAuth;
  only?: string[];
  except?: string[];
}

/**
 * The MCP servers a token's person, or their org, adds for their own
 * agents, reached over Streamable HTTP.
 *
 *     await wardrik.servers.add({ name: "crm", url: "https://mcp.crm.example/mcp",
 *                                 auth: { secret: { name: "crm-key" } } });
 *     const { servers } = await wardrik.servers.list();
 */
export class Servers {
  readonly #http: Http;

  /** @internal */
  constructor(http: Http) {
    this.#http = http;
  }

  /** The servers added, each by its name, URL and how its agents sign in. */
  list(options: ServerOptions = {}): Promise<ServerList> {
    return this.#http.json("GET", "/v1/servers", request(options));
  }

  /** Adds a server: that its agents can call it now, or where to sign in to it first. */
  add(fields: ServerFields, options: ServerOptions = {}): Promise<ServerAdded> {
    return this.#http.json("POST", "/v1/servers", { ...request(options), body: fields });
  }

  /** Removes the server `name`, so the owner's agents can no longer call it. */
  async remove(name: string, options: ServerOptions = {}): Promise<void> {
    await this.#http.send("DELETE", `/v1/servers/${encodeURIComponent(name)}`, request(options));
  }
}

const request = ({ owner, signal }: ServerOptions) => ({ query: { owner }, signal });
