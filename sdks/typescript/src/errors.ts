import type { ErrorBody } from "./protocol.ts";

/** What went wrong, as the API answered it: its status and error body. */
export class TarsError extends Error {
  /** The HTTP status. */
  readonly status: number;
  /** A low-cardinality code, such as `not_found` or `conflict`. */
  readonly type: ErrorBody["error"]["type"] | "unknown";
  /** The `Request-Id` the API answered with, to quote when asking for help. */
  readonly requestId: string | undefined;
  /** On a `gap`, the first sequence the log still holds. */
  readonly oldest: number | undefined;

  constructor(
    status: number,
    error: { type: TarsError["type"]; message: string; oldest?: number | undefined },
    requestId?: string | undefined,
  ) {
    super(error.message);
    this.name = "TarsError";
    this.status = status;
    this.type = error.type;
    this.requestId = requestId;
    this.oldest = error.oldest;
  }

  /** The error an answer of 400 or above holds. */
  static async from(response: Response): Promise<TarsError> {
    const requestId = response.headers.get("request-id") ?? undefined;

    try {
      const body = (await response.json()) as ErrorBody;
      return new TarsError(response.status, body.error, requestId);
    } catch {
      const message = `${response.status} ${response.statusText}`.trim();
      return new TarsError(response.status, { type: "unknown", message }, requestId);
    }
  }
}
