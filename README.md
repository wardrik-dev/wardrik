# WardrikHTTP

Serves [Wardrik](https://hexdocs.pm/wardrik) over HTTP. Every operation is a JSON route, and
agents' events stream as server-sent events.

## Install

```elixir
def deps do
  [
    {:wardrik, "~> 0.1.0-rc.7"},
    {:wardrik_http, "~> 0.1.0-rc.2"}
  ]
end
```

## Serve HTTP requests

Application supervision fragment: configure [MyApp.AgentRuntime](https://hexdocs.pm/wardrik/running-wardrik.html) first.
Define the authenticator below before starting this tree.

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

This Phoenix example requires your app's running `MyAppWeb.Endpoint` and a token signed with the `"wardrik"` salt.

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

Set `TOKEN` to a token signed by the Phoenix app above. Install `jq` to extract the response cursor.

```sh
export WARDRIK_URL=http://127.0.0.1:4000
: "${TOKEN:?Set TOKEN to your application token}"

curl --fail-with-body -X PUT "$WARDRIK_URL/v1/agents/agt_1" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"anthropic:claude-haiku-4-5","instructions":"Summarize incident reports."}'

response=$(curl --fail-with-body -X POST "$WARDRIK_URL/v1/agents/agt_1/messages" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"content":"Summarize this incident: The API returned errors for five minutes."}')
cursor=$(printf '%s' "$response" | jq -er '.message.cursor')

curl --fail-with-body -N -G "$WARDRIK_URL/v1/agents/agt_1/events" \
  --data-urlencode "after=$cursor" \
  -H "Authorization: Bearer $TOKEN" -H 'Accept: text/event-stream'
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
plug(Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  json_decoder: Phoenix.json_library(),
  body_reader: Wardrik.HTTP.body_reader()
)
```

## Run tools in your own process

A tool worker is your program, offering agents tools over a WebSocket to `/v1/workers`. Wardrik
is the MCP client. The tools run in your process, with your code and keys.

```elixir
scope = MyApp.AgentRuntime.as("maria")

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
