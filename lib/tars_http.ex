defmodule TarsHTTP do
  @moduledoc """
  Tars's agents over HTTP: a versioned JSON API, and each agent's event log
  as server-sent events a client resumes after any disconnect.

  A daemon serves it on `127.0.0.1:4747` (see `TarsHTTP.Listener`), and
  `config.yaml` moves it:

      http:
        port: 4747
        ip: 0.0.0.0     # every interface; loopback unless set

  ## Tokens

  Every request presents a token, as `Authorization: Bearer tars_…`. A token
  reaches the agents whose keys start with its scope, and an agent outside it
  is answered as one that does not exist. See `TarsHTTP.Token`; from a shell:

      tars token create ci --scope acme/
      tars token create laptop --all
      tars token list
      tars token revoke 3f9a61c0d4e2

  ## Routes

  An agent's key, `org/user/name`, is its path under `/v1/agents/`.

  | Route | Answers |
  | --- | --- |
  | `GET /v1/agents` | the agents the token reaches |
  | `GET /v1/agents/:key` | the agent's snapshot, with `sequence`, the last event its log has written |
  | `GET /v1/agents/:key/events` | its log as server-sent events, with `Accept: text/event-stream`; otherwise a page of it as JSON |
  | `POST /v1/agents/:key/messages` | queues a message for the agent to answer, `202` |
  | `POST /v1/agents/:key/interrupts/:id` | approves or rejects a call the agent is waiting on |
  | `POST /v1/agents/:key/cancel` | stops what the agent is doing, and drops what is queued, `202` |

  `TarsHTTP.Resource` shows what each answers.

  ### Events

  The stream starts after `Last-Event-ID`, or after `?starting_after=`, and
  without either after the last event written when it connects. A page takes
  `?starting_after=`, `0` by default, and `?limit=`, up to 500. Where events
  after the sequence have been dropped, either answers `410` with the oldest
  one still held; read the snapshot and follow from its `sequence`. See
  `TarsHTTP.EventStream`.

  ### Messages

      POST /v1/agents/acme/ops/triage/messages
      {"id": "msg_01", "parts": [{"type": "text", "content": "What's on fire?"}]}

  `content` in place of `parts` is the text alone. `id` is optional, and a
  message sent again under the same id is taken once. The answer names it:
  `{"message": {"id": "msg_01"}}`.

  ### Interrupts

      POST /v1/agents/acme/ops/triage/interrupts/toolu_01
      {"decision": "reject", "reason": "Not this quarter."}

  `decision` is `approve` or `reject`. The decision is recorded as made by
  the token, and answers `409` when the agent is not waiting on that call,
  and `503` when the agent could not record it.

  ## Every response

  Carries a `Request-Id` header, the caller's own where it sent one, and is
  logged under it. An error is `{"error": {"type": …, "message": …}}`.
  """
end
