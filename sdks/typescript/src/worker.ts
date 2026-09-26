import { setTimeout as sleep } from "node:timers/promises";
import {
  McpServer,
  type CallToolResult,
  type JSONRPCMessage,
  type ServerContext,
  type StandardSchemaWithJSON,
  type Transport,
} from "@modelcontextprotocol/server";
import { WardrikError } from "./errors.ts";
import type { Http } from "./http.ts";

/** What a tool's `run` is given beside its arguments. */
export interface ToolContext {
  /**
   * The call's idempotency key, the same each time Wardrik runs this call.
   * Pass it on to what the tool changes, such as a payment API, so a call
   * run again after a crash has no second effect.
   */
  idempotencyKey: string | undefined;
  /** Aborts when Wardrik stops waiting for the call. */
  signal: AbortSignal;
}

/** A tool that runs in this process, for agents to call. */
export interface ToolDefinition<Input extends StandardSchemaWithJSON = StandardSchemaWithJSON> {
  /** Its name. Agents see it as `workers__<name>`. */
  name: string;
  title?: string;
  /** What it does, for the model. */
  description?: string;
  /** Its arguments, as a schema such as `z.object({ … })`. */
  input: Input;
  /**
   * Whether running it again with the same idempotency key has no second
   * effect. A call Wardrik cannot tell finished, because its agent was lost
   * while the call was running, runs again where every worker offering the
   * tool says so, and waits for a person otherwise.
   */
  idempotent?: boolean;
  /** Whether it changes nothing, which makes it safe to run again as well. */
  readOnly?: boolean;
  /**
   * Does the work. An object is answered as the call's result, a string as
   * text, and a thrown error as a failed call the model is told about.
   */
  run(args: StandardSchemaWithJSON.InferOutput<Input>, context: ToolContext): unknown;
}

export interface WorkOptions {
  /** Ends the work, closing the socket. */
  signal?: AbortSignal | undefined;
}

const firstDelay = 500;
const lastDelay = 30_000;

/** A result as MCP's `CallToolResult` carries it. */
function answer(value: unknown): CallToolResult {
  if (value === undefined || value === null) return { content: [] };
  if (typeof value === "string") return { content: [{ type: "text", text: value }] };

  const text = JSON.stringify(value);
  const isObject = typeof value === "object" && !Array.isArray(value);

  return {
    content: [{ type: "text", text }],
    ...(isObject ? { structuredContent: value as Record<string, unknown> } : {}),
  };
}

function failed(error: unknown): CallToolResult {
  const text = error instanceof Error ? error.message : String(error);
  return { isError: true, content: [{ type: "text", text }] };
}

/** The tools this process offers, and the socket it offers them over. */
export class Worker {
  readonly #tools = new Map<string, ToolDefinition<any>>();
  readonly #name: string;
  readonly #version: string;
  #server: McpServer | undefined;

  constructor(name: string, version: string) {
    this.#name = name;
    this.#version = version;
  }

  /** Offers `tool`, in place of any of the same name, to a socket already open too. */
  add<Input extends StandardSchemaWithJSON>(tool: ToolDefinition<Input>): void {
    const replaced = this.#tools.has(tool.name);
    this.#tools.set(tool.name, tool);

    if (this.#server && !replaced) this.#register(this.#server, tool);
  }

  /**
   * Holds a socket to the server open and answers calls over it, until
   * `signal` aborts. A dropped socket is opened again, waiting longer each
   * time up to 30 seconds. Throws a `WardrikError` when the token is refused.
   */
  async work(http: Http, options: WorkOptions = {}): Promise<void> {
    const { signal } = options;
    const url = http.url.replace(/^http/, "ws") + "/v1/workers";
    let delay = firstDelay;

    while (!signal?.aborted) {
      try {
        await this.#check(http, signal);
        const opened = Date.now();
        await this.#serve(url, http, signal);
        if (Date.now() - opened > lastDelay) delay = firstDelay;
      } catch (error) {
        if (error instanceof WardrikError && error.status < 500) throw error;
        if (signal?.aborted) return;
      }

      await sleep(delay, undefined, signal ? { signal } : {}).catch(() => {});
      delay = Math.min(delay * 2, lastDelay);
    }
  }

  // A WebSocket that is refused says nothing of why, so the token is tried
  // first with a plain request, which the server answers 426 when it is good.
  async #check(http: Http, signal: AbortSignal | undefined): Promise<void> {
    await http.send("GET", "/v1/workers", { accept: [426], signal });
  }

  async #serve(url: string, http: Http, signal: AbortSignal | undefined): Promise<void> {
    const server = new McpServer({ name: this.#name, version: this.#version });
    for (const tool of this.#tools.values()) this.#register(server, tool);

    const transport = new SocketTransport(url, http.token);
    await server.connect(transport);
    this.#server = server;

    const closed = new Promise<void>((resolve) => {
      const onclose = transport.onclose;
      transport.onclose = () => {
        onclose?.();
        resolve();
      };
    });

    const stop = () => void transport.close();
    signal?.addEventListener("abort", stop, { once: true });

    try {
      await closed;
    } finally {
      signal?.removeEventListener("abort", stop);
      if (this.#server === server) this.#server = undefined;
    }
  }

  #register(server: McpServer, tool: ToolDefinition<any>): void {
    const annotations = {
      ...(tool.idempotent === undefined ? {} : { idempotentHint: tool.idempotent }),
      ...(tool.readOnly === undefined ? {} : { readOnlyHint: tool.readOnly }),
    };

    server.registerTool(
      tool.name,
      {
        ...(tool.title === undefined ? {} : { title: tool.title }),
        ...(tool.description === undefined ? {} : { description: tool.description }),
        inputSchema: tool.input,
        annotations,
      },
      async (args: unknown, ctx: ServerContext) => {
        const key = ctx.mcpReq._meta?.["idempotencyKey"];
        const context = {
          idempotencyKey: typeof key === "string" ? key : undefined,
          signal: ctx.mcpReq.signal,
        };

        try {
          return answer(await tool.run(args, context));
        } catch (error) {
          return failed(error);
        }
      },
    );
  }
}

/** MCP over one WebSocket, one JSON-RPC message to a text frame. */
class SocketTransport implements Transport {
  onclose?: () => void;
  onerror?: (error: Error) => void;
  onmessage?: (message: JSONRPCMessage) => void;

  readonly #url: string;
  readonly #token: string;
  #socket: WebSocket | undefined;

  constructor(url: string, token: string) {
    this.#url = url;
    this.#token = token;
  }

  start(): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(this.#url, {
        headers: { authorization: `Bearer ${this.#token}` },
      });
      let open = false;

      socket.onopen = () => {
        open = true;
        resolve();
      };

      socket.onerror = () => {
        const error = new Error(`The socket to ${this.#url} failed`);
        if (open) this.onerror?.(error);
        else reject(error);
      };

      socket.onclose = () => this.onclose?.();

      socket.onmessage = (event: MessageEvent) => {
        try {
          this.onmessage?.(JSON.parse(String(event.data)) as JSONRPCMessage);
        } catch (error) {
          this.onerror?.(error as Error);
        }
      };

      this.#socket = socket;
    });
  }

  async send(message: JSONRPCMessage): Promise<void> {
    this.#socket?.send(JSON.stringify(message));
  }

  async close(): Promise<void> {
    this.#socket?.close();
  }
}
