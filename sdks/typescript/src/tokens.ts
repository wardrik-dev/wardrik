import type { Http } from "./http.ts";
import type { Token, Tokens as TokenList, TokenIssued } from "./protocol.ts";

/** A token to make: its name, the resources it reaches, and the roles it holds there. */
export interface TokenFields {
  name: string;
  /**
   * What it reaches, each a resource pattern: `acme/agent/*` for acme's own agents, `acme/@jon/*`
   * for everything of a user's, `acme/*` for the org and its users', or `*` for everything.
   */
  resources: string[];
  /** Each a named set of actions: reader, messenger, approver, definer, worker or owner. */
  roles: string[];
  /**
   * The policy every agent it defines runs under, ahead of the agent's own, by the name the
   * server holds it under: what IAM calls a permissions boundary. The maker's where left out.
   */
  policy?: string;
  /** How many seconds it works for; the server's own lifetime for API tokens where left out. */
  expiresIn?: number;
}

/**
 * The API's tokens, for a token owning `*` or `deployment/*`. A token made
 * here acts for whoever made it, and its secret is given this once.
 *
 *     const { token, secret } = await wardrik.tokens.create({
 *       name: "ci", resources: ["acme/agent/*"], roles: ["reader", "messenger"], expiresIn: 86_400 });
 *     await wardrik.tokens.revoke(token.id);
 */
export class Tokens {
  readonly #http: Http;

  /** @internal */
  constructor(http: Http) {
    this.#http = http;
  }

  /** Every token, oldest first, never a secret. */
  list(): Promise<TokenList> {
    return this.#http.json("GET", "/v1/tokens");
  }

  /** Makes a token: it, and the secret that presents it. */
  create({ name, resources, roles, policy, expiresIn }: TokenFields): Promise<TokenIssued> {
    return this.#http.json("POST", "/v1/tokens", {
      body: { name, resources, roles, policy, expires_in: expiresIn },
    });
  }

  /** Stops the token `id` working, and ends what is open on it: the token, as it was. */
  async revoke(id: string): Promise<Token> {
    const answer = await this.#http.json<{ token: Token }>("DELETE", `/v1/tokens/${encodeURIComponent(id)}`);
    return answer.token;
  }
}
