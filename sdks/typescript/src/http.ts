import { WardrikError } from "./errors.ts";

export interface Request {
  body?: unknown;
  headers?: Record<string, string>;
  query?: Record<string, string | number | string[] | undefined>;
  signal?: AbortSignal | undefined;
  /** Statuses of 400 and above to answer with rather than throw on. */
  accept?: number[];
}

/** Requests to one server, as one token. */
export class Http {
  readonly url: string;
  readonly token: string;
  readonly #fetch: typeof fetch;

  constructor(url: string, token: string, fetcher: typeof fetch) {
    this.url = url.replace(/\/+$/, "");
    this.token = token;
    this.#fetch = fetcher;
  }

  /** The response to `method` on `path`, throwing a `WardrikError` for 400 and above. */
  async send(method: string, path: string, request: Request = {}): Promise<Response> {
    const headers: Record<string, string> = {
      authorization: `Bearer ${this.token}`,
      ...request.headers,
    };

    let body: string | undefined;
    if (request.body !== undefined) {
      headers["content-type"] = "application/json";
      body = JSON.stringify(request.body);
    }

    const response = await this.#fetch(this.#address(path, request.query), {
      method,
      headers,
      ...(body === undefined ? {} : { body }),
      ...(request.signal === undefined ? {} : { signal: request.signal }),
    });

    if (response.status >= 400 && !request.accept?.includes(response.status)) {
      throw await WardrikError.from(response);
    }

    return response;
  }

  /** The JSON body of the answer to `method` on `path`, or `undefined` for a 204. */
  async json<T>(method: string, path: string, request: Request = {}): Promise<T> {
    const response = await this.send(method, path, request);
    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }

  #address(path: string, query: Request["query"]): string {
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(query ?? {})) {
      for (const one of [value ?? []].flat()) params.append(key, String(one));
    }

    const search = params.size > 0 ? `?${params}` : "";
    return this.url + path + search;
  }
}

/**
 * An agent's path under `/v1/agents/`: each segment of its key, `org/name` or
 * `org/@user/name`, encoded on its own, with the `@` that marks a user kept.
 */
export function agentPath(key: string): string {
  const segments = key.split("/");
  const user = segments.length === 3 && segments[1]!.startsWith("@");

  if (!(segments.length === 2 || user) || segments.some((segment) => segment === "" || segment === "@")) {
    throw new TypeError(`An agent's key is org/name or org/@user/name; got ${JSON.stringify(key)}`);
  }

  return "/v1/agents/" + segments.map((segment) => encodeURIComponent(segment).replace(/^%40/, "@")).join("/");
}
