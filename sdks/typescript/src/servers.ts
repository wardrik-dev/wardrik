import type { Http } from "./http.ts";
import type { ServerAdded, Servers as ServerList } from "./protocol.ts";

/** What a request about servers takes beside its owner. */
export interface ServerOptions {
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
 * The MCP servers an owner adds for their own agents, reached over
 * Streamable HTTP. The owner is an org, `acme`, or a person, `acme/@jon`.
 *
 *     await wardrik.servers.add("acme", { name: "crm", url: "https://mcp.crm.example/mcp",
 *                                         auth: { secret: { name: "crm-key" } } });
 *     const { servers } = await wardrik.servers.list("acme");
 */
export class Servers {
  readonly #http: Http;

  /** @internal */
  constructor(http: Http) {
    this.#http = http;
  }

  /** The servers `owner` added, each by its name, URL and how its agents sign in. */
  list(owner: string, options: ServerOptions = {}): Promise<ServerList> {
    return this.#http.json("GET", "/v1/servers", request(owner, options));
  }

  /** Adds a server for `owner`: that its agents can call it now, or where to sign in to it first. */
  add(owner: string, fields: ServerFields, options: ServerOptions = {}): Promise<ServerAdded> {
    return this.#http.json("POST", "/v1/servers", { ...request(owner, options), body: fields });
  }

  /** Removes the server `name` `owner` added, so their agents can no longer call it. */
  async remove(owner: string, name: string, options: ServerOptions = {}): Promise<void> {
    await this.#http.send(
      "DELETE",
      `/v1/servers/${encodeURIComponent(name)}`,
      request(owner, options),
    );
  }
}

const request = (owner: string, { signal }: ServerOptions) => ({ query: { owner }, signal });
