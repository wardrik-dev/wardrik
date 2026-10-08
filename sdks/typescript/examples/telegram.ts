// Telegram in front of one agent: what you send reaches it, its answers come
// back, each call it waits on comes with Approve and Deny, /stop stops its
// turn, and message_me lets it write to you first.
//
//   wardrik token create telegram --scope default/@jon/ --can read,message,decide,serve
//   WARDRIK_TOKEN=wardrik_… TELEGRAM_BOT_TOKEN=… TELEGRAM_CHAT_ID=… node telegram.ts

import { setTimeout as sleep } from "node:timers/promises";
import { z } from "zod";
import { Wardrik } from "../src/index.ts";

const bot = `https://api.telegram.org/bot${process.env.TELEGRAM_BOT_TOKEN}`;
const chat = Number(process.env.TELEGRAM_CHAT_ID);

const wardrik = new Wardrik({ name: "telegram" });
const agent = wardrik.agent(process.env.WARDRIK_AGENT ?? "default/@jon/assistant");

async function telegram(method: string, body: object): Promise<any> {
  const response = await fetch(`${bot}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const answer: any = await response.json();
  if (!answer.ok) throw new Error(`${method}: ${answer.description}`);
  return answer.result;
}

const say = (text: string, extra: object = {}) =>
  telegram("sendMessage", { chat_id: chat, text: text.slice(0, 4096), ...extra });

wardrik.tool({
  name: "message_me",
  description:
    "Send your person a Telegram message, for what they did not ask about and would want to know " +
    "now. Your answers to what they send reach them anyway.",
  input: z.object({ text: z.string() }),
  run: async ({ text }) => {
    await say(text);
    return "sent";
  },
});

const textOf = (parts: { type: string; content?: string }[]) =>
  parts
    .filter((part) => part.type === "text")
    .map((part) => part.content)
    .join("");

const calls = new Map<string, string>(); // a tool call's id, to what it was called with
const sent = new Set<string>(); // the ids of messages sent from Telegram
const answering = new Set<string>(); // the runs answering them
const waiting = new Map<string, string>(); // a button's number, to the call it decides
let buttons = 0;

async function follow() {
  for await (const event of agent.events()) {
    const run = event.traceparent.split("-")[1] ?? "";

    if (event.type === "wardrik.run.started") {
      if (event.data.run.message_ids?.some((id) => sent.has(id))) answering.add(run);
    } else if (event.type === "wardrik.message.completed") {
      for (const part of event.data.message.parts) {
        if (part.type === "tool_call" && part.id) {
          calls.set(part.id, `${part.name} ${JSON.stringify(part.arguments ?? {}, null, 2)}`);
        }
      }

      const reply = textOf(event.data.message.parts);
      if (reply && answering.has(run)) await say(reply);
    } else if (event.type === "wardrik.run.failed" && answering.has(run)) {
      await say(`That failed: ${event.data.error.message}`);
    } else if (event.type === "wardrik.run.interrupted") {
      for (const interrupt of event.data.interrupts) {
        const n = String(++buttons);
        waiting.set(n, interrupt.id);
        const call = calls.get(interrupt.tool_call_id ?? "");
        const outside = interrupt.labels?.includes("outside")
          ? "\n\nIt has read content from outside, which may be what asked for this."
          : "";
        await say(`${interrupt.message}${outside}${call ? `\n\n${call}` : ""}`, {
          reply_markup: {
            inline_keyboard: [
              [
                { text: "Approve", callback_data: `approve ${n}` },
                { text: "Deny", callback_data: `deny ${n}` },
              ],
            ],
          },
        });
      }
    }
  }
}

// A call decided already, from a shell or another press, answers 409.
async function decide(decision: string, call: string | undefined): Promise<string> {
  if (call === undefined) return "Already decided";

  const deciding =
    decision === "approve" ? agent.approve(call) : agent.reject(call, "Denied in Telegram.");
  return deciding.then(
    () => (decision === "approve" ? "Approved" : "Denied"),
    () => "Already decided",
  );
}

async function listen() {
  for (let offset = 0; ; ) {
    // Telegram out of reach is asked again shortly, as the SDK asks the daemon again.
    const updates = await telegram("getUpdates", {
      offset,
      timeout: 50,
      allowed_updates: ["message", "callback_query"],
    }).catch(async (error) => {
      console.error(error);
      await sleep(5000);
      return [];
    });

    for (const { update_id, message, callback_query: press } of updates) {
      offset = update_id + 1;

      if (message?.chat.id === chat && message.text === "/stop") {
        await agent.cancel();
        await say("Stopped.");
      } else if (message?.chat.id === chat && message.text) {
        const id = crypto.randomUUID();
        sent.add(id);
        await agent.send(message.text, { id });
      } else if (press?.message?.chat.id === chat) {
        const [decision, n] = press.data.split(" ");
        const answer = await decide(decision, waiting.get(n));
        waiting.delete(n);
        await telegram("answerCallbackQuery", { callback_query_id: press.id, text: answer });
        await telegram("editMessageReplyMarkup", {
          chat_id: chat,
          message_id: press.message.message_id,
        });
      }
    }
  }
}

await Promise.all([wardrik.work(), follow(), listen()]);
