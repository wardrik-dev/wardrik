# Changelog

## 0.1.0-rc.2

### Breaking

- Each path parameter is one segment, so an agent ID is one percent-encoded segment, `/` and
  all. An operation on a conversation also matches its route under
  `/v1/agents/{agent}/conversations/{conversation}`, which gives `"conversation"`.
- `:authenticator` is required, and `WardrikHTTP.Bearer` and API tokens are gone. Options are
  checked with `NimbleOptions`.
- `c:WardrikHTTP.Authenticator.authenticate/2` takes a `WardrikHTTP.Authenticator.Request`, with
  the conn, the server and the instance, then its options.

## 0.1.0-rc.1 (2026-10-30)

- Every operation of `WardrikProtocol` at its route, built from the OpenAPI document, each run with
  `Wardrik.run/3`.
- API tokens as `Authorization: Bearer`, or your own `WardrikHTTP.Authenticator`.
- Agents' events as server-sent events, resumed after `Last-Event-ID`, kept open with a comment,
  and ended once the token is revoked.
- Webhooks, read as they came, with `WardrikHTTP.BodyReader` for apps that parse bodies first.
- Chat apps' requests at `/v1/channels/{channel}/{path}`, read as they came, handed to Wardrik's
  channel of that name, and answered as the channel says.
- Tool workers: MCP servers that dial in over a WebSocket at `/v1/workers`, offering agents tools
  that run in their own process.
- The sign-in pages at `/oauth/`, and the OpenAPI document at `/v1/openapi.json`.
