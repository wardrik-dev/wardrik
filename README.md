# WardrikHTTP

Serves [Wardrik](https://hexdocs.pm/wardrik) over HTTP. Every operation is a JSON route. Agents'
events stream as server-sent events, which a client resumes after a disconnect.

## Install

```elixir
def deps do
  [
    {:wardrik, "~> 0.1.0-rc.1"},
    {:wardrik_http, "~> 0.1.0-rc.1"}
  ]
end
```

## Serve it

Add `Wardrik.HTTP` to your supervision tree after Wardrik:

```elixir
defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app
end

# config/runtime.exs
config :my_app, MyApp.AgentRuntime,
  store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"},
  keys: [System.fetch_env!("WARDRIK_KEY")]

# application.ex
children = [
  MyApp.AgentRuntime,
  {Wardrik.HTTP,
   wardrik: MyApp.AgentRuntime, authenticator: {MyAppWeb.WardrikSession, []}, port: 4000}
]
```

It also takes Bandit's options, like `:ip`. It serves plain HTTP, so put a TLS-terminating proxy
in front of it on a network.

`Wardrik.HTTP` passes `MyApp.AgentRuntime` to `WardrikHTTP` as its server. Use `WardrikHTTP` directly
only for a `Wardrik.Server` of your own.

## Authenticate requests

`:authenticator` is required: a `WardrikHTTP.Authenticator` that says who each request comes from,
by your app's own sessions or tokens. Wardrik's `:authorizer` then decides what they may do. See
[Who may do what](https://hexdocs.pm/wardrik/access.html).

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

Define an agent, send it a message, and follow its log:

```sh
export TOKEN=...  # what your authenticator takes

curl -X PUT localhost:4000/v1/agents/agt_01JF8X5RQ2 \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"model": "anthropic:claude-haiku-4-5", "instructions": "You watch the incident queue."}'

curl -X POST localhost:4000/v1/agents/agt_01JF8X5RQ2/messages \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"content": "What is on fire?"}'
#=> {"message": {"id": "msg_Xq3f...", "cursor": "W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ"}}

curl -N localhost:4000/v1/agents/agt_01JF8X5RQ2/events?after=W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: text/event-stream"
#=> id: W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDNdXQ
#=> data: {"specversion":"1.0","type":"wardrik.run.completed",...}
```

An agent's ID is whatever your app gave it, sent as one percent-encoded path segment. A
conversation of the agent adds `conversations/{conversation}`:

```sh
curl -X POST localhost:4000/v1/agents/agt_01JF8X5RQ2/conversations/C1-1696.1234/messages \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"content": "And now?"}'
```

Event streams:

* Each event's `id` is a cursor.
* A stream starts after `Last-Event-ID` or `?after=`. With neither, it starts at the next event.
* Without `Accept: text/event-stream`, the same route returns a page of events as JSON.
* An idle stream sends a comment every 15 seconds.
* A stream ends once the request no longer authenticates.

`GET /v1/openapi.json` lists every route, for client generators. Errors are the protocol's
`{"error": {"type": ..., "message": ...}}`. Every response has a `request-id` header.

## Receive webhooks

A trigger with a `webhook` receives requests at `POST /v1/hooks/{agent}/{trigger}`. These skip the
authenticator. The request proves itself with the trigger's secret:

```elixir
{:ok, _vsn} =
  WardrikVault.put(
    MyApp.AgentRuntime.Vault,
    %WardrikVault.Secret{
      principal: Wardrik.principal("acme"),
      name: "ISSUES_HOOK",
      value: System.fetch_env!("ISSUES_HOOK")
    },
    kind: :signing_secret
  )

Wardrik.Agent.define(scope, "agt_01JF8X5RQ2",
  model: "anthropic:claude-haiku-4-5",
  triggers: [%{name: "issues", webhook: %{secret: "${ISSUES_HOOK}"}, prompt: "Triage it."}]
)
```

Point the service at `https://agents.example.com/v1/hooks/agt_01JF8X5RQ2/issues`. See
[Trigger agents](https://hexdocs.pm/wardrik/triggers.html) for how requests are verified.

## Run tools in your own process

A tool worker is your own program offering agents tools. The tools run in its process, with its
code, data and keys. The worker connects to Wardrik, so Wardrik never needs to reach it.

1. Give it credentials your authenticator takes, for a principal your authorizer allows
   `agent.serve` on the agents it serves.

2. The worker opens a WebSocket to `/v1/workers` with them and acts as an MCP server.
   Wardrik sends `initialize` and `tools/list`, then a `tools/call` for each call an agent makes:

   ```json
   {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
    "params": {"name": "refund_order", "arguments": {"order": "A1"},
               "_meta": {"agent": {"key": "agt_01JF8X5RQ2"},
                         "run": "4bf92f3577b34da6a3ce929d0e0e4736",
                         "principal": "user_42", "idempotencyKey": "call_1"}}}
   ```

3. Agents name workers' tools as `workers/*`:

   ```elixir
   Wardrik.Agent.define(scope, "agt_01JF8X5RQ2",
     model: "anthropic:claude-haiku-4-5",
     tools: ["workers/*"],
     policy: [ask: ["workers/refund_order"]]
   )
   ```

The model sees the tool as `workers__refund_order`. A tool without `readOnlyHint` counts as one
that changes things, and the agent's policy decides it like any other. A result's
`_meta.costUsd` is what the call cost, and budgets count it. See `WardrikHTTP.Worker` for the
whole exchange.

A worker's tools go when its socket closes and return when it reconnects. Each turn uses the tools
offered when it starts. Each call goes to a worker connected at that moment.

A call whose worker disconnects, or doesn't answer within a minute, may have run:

* If every worker offering the tool marks it `readOnlyHint` or `idempotentHint`, the call runs
  again on whichever worker offers it then, with the same `idempotencyKey`.
* Otherwise it waits on a person as `in_doubt`, to approve running it again or deny it.

## Sign people in

If Wardrik signs people in, `/oauth/` serves the pages a sign-in returns to. Set `page` to that
URL:

```elixir
config :my_app, MyApp.AgentRuntime,
  keys: [System.fetch_env!("WARDRIK_KEY")],
  oauth: [
    page: "https://agents.example.com/oauth",
    providers: [
      github: [
        issuer: "https://github.com/login/oauth",
        client_id: System.fetch_env!("GITHUB_CLIENT_ID"),
        client_secret: System.fetch_env!("GITHUB_CLIENT_SECRET"),
        scopes: ~w(repo),
        flow: :device
      ]
    ]
  ]
```

See [Credentials and sign-ins](https://hexdocs.pm/wardrik/credentials.html).

## In a Phoenix app

Forward a path to it from your router, in place of the child above:

```elixir
forward "/agents", Wardrik.HTTP,
  wardrik: MyApp.AgentRuntime,
  authenticator: {MyAppWeb.WardrikSession, []}
```

Routes are then under `/agents`, as `/agents/v1/agents/agt_01JF8X5RQ2`. Sign-in pages are at
`/agents/oauth`.

Webhook signatures cover the exact bytes sent. If your endpoint parses bodies first, have
`Plug.Parsers` keep them:

```elixir
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  json_decoder: Phoenix.json_library(),
  body_reader: Wardrik.HTTP.body_reader()
```

## License

Apache-2.0
