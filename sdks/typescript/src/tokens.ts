import type { Http } from "./http.ts";
import type { Token, Tokens as TokenList, TokenIssued } from "./protocol.ts";

/** A token to make: its name, the agents it reaches, and the roles it holds there. */
export interface TokenFields {
  name: string;
  /** The agents' prefix: `acme/`, `acme/@jon/`, `acme/*`, an agent's key, or `""` for every agent. */
  scope: string;
  /** Each a named set of actions: reader, messenger, approver, definer, worker or owner. */
  roles: string[];
  /** How many seconds it works for; the server's own lifetime for API tokens where left out. */
  expiresIn?: number;
}

/**
 * The API's tokens, for a token owning every agent. A token made here acts
 * for whoever made it, and its secret is given this once.
 *
 *     const { token, secret } = await wardrik.tokens.create({
 *       name: "ci", scope: "acme/", roles: ["reader", "messenger"], expiresIn: 86_400 });
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
  create({ name, scope, roles, expiresIn }: TokenFields): Promise<TokenIssued> {
    return this.#http.json("POST", "/v1/tokens", {
      body: { name, scope, roles, ...(expiresIn === undefined ? {} : { expires_in: expiresIn }) },
    });
  }

  /** Stops the token `id` working, and ends what is open on it: the token, as it was. */
  async revoke(id: string): Promise<Token> {
    const answer = await this.#http.json<{ token: Token }>("DELETE", `/v1/tokens/${encodeURIComponent(id)}`);
    return answer.token;
  }
}
