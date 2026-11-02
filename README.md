# WardrikHTTP

Serves [Wardrik](https://hexdocs.pm/wardrik) over HTTP. Every operation is a JSON route, and
agents' events stream as server-sent events.

## Install

```elixir
def deps do
  [
    {:wardrik, "~> 0.1.0-rc.2"},
    {:wardrik_http, "~> 0.1.0-rc.2"}
  ]
end
```

## Serve it

```elixir
children = [
  MyApp.AgentRuntime,
  {Wardrik.HTTP,
   wardrik: MyApp.AgentRuntime, authenticator: {MyAppWeb.WardrikSession, []}, port: 4000}
]
```

* It also takes Bandit's options, like `:ip`.
* It serves plain HTTP. Put a TLS proxy in front of it.
* In Phoenix, forward a path to it instead:
  `forward "/agents", Wardrik.HTTP, wardrik: MyApp.AgentRuntime, authenticator: {MyAppWeb.WardrikSession, []}`.

## Authenticate requests

An authenticator turns each request into a scope. Wardrik's authorizer then decides what it may
do. See [Who may do what](https://hexdocs.pm/wardrik/access.html).

```elixir
defmodule MyAppWeb.WardrikSession do
  @behaviour WardrikHTTP.Authenticator

  @impl true
  def authenticate(%{conn: conn, wardrik: wardrik}, _opts) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, id} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "wardrik", token, max_age: 86_400) do
      {:ok, Wardrik.as(wardrik, id)}
    else
      _not_signed_in -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
    end
  end
end
```

## Talk to agents

```sh
curl -X PUT localhost:4000/v1/agents/agt_1 \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"model": "anthropic:claude-haiku-4-5", "instructions": "You watch the incident queue."}'

curl -X POST localhost:4000/v1/agents/agt_1/messages \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"content": "What is on fire?"}'
#=> {"message": {"id": "msg_Xq3f...", "cursor": "W1siYWd0XzEiLG51bGwsNDFdXQ"}}

curl -N localhost:4000/v1/agents/agt_1/events?after=W1siYWd0XzEiLG51bGwsNDFdXQ \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: text/event-stream"
#=> id: W1siYWd0XzEiLG51bGwsNDNdXQ
#=> data: {"specversion":"1.0","type":"wardrik.run.completed",...}
```

* An agent ID is one percent-encoded path segment.
* A conversation's routes add `conversations/{conversation}`, as
  `/v1/agents/agt_1/conversations/C1/messages`.
* An event stream resumes after `Last-Event-ID` or `?after=`. Without `text/event-stream`, the
  route returns a page of JSON.
* `GET /v1/openapi.json` lists every route.
* Errors are `{"error": {"type": ..., "message": ...}}`.

## Receive webhooks

A trigger's webhook takes requests at `POST /v1/hooks/{agent}/{trigger}`, with no authenticator.
The request proves itself with the trigger's secret. See
[Trigger agents](https://hexdocs.pm/wardrik/triggers.html).

If Phoenix parses bodies first, keep the raw bytes for the signature check:

```elixir
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  json_decoder: Phoenix.json_library(),
  body_reader: Wardrik.HTTP.body_reader()
```

## Run tools in your own process

A tool worker is your program, offering agents tools over a WebSocket to `/v1/workers`. Wardrik
is the MCP client. The tools run in your process, with your code and keys.

```elixir
Wardrik.Agent.define(scope, "agt_1",
  model: "anthropic:claude-haiku-4-5",
  tools: ["workers/*"],
  policy: [ask: ["workers/refund_order"]]
)
```

* The worker authenticates like any request. Your authorizer must allow it `agent.serve`.
* If a worker goes away mid-call, a read-only or idempotent tool runs again elsewhere. Any other
  waits on a person as `in_doubt`.
* See `WardrikHTTP.Worker` for the exchange.

## Sign people in

With Wardrik's `:oauth` set, `/oauth/` serves the pages a sign-in returns to. Set its `page` to
that URL. See
[Credentials and sign-ins](https://hexdocs.pm/wardrik/credentials.html).

## License

Apache-2.0
