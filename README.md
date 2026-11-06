# WardrikTriggers

Asks agents something on a clock, when a feed has new entries, or when a service sends a webhook.

With [Wardrik](https://hexdocs.pm/wardrik), triggers live in an agent's definition and this is set
up for you. See [Trigger agents](https://hexdocs.pm/wardrik/triggers.html).

## Install

```elixir
def deps do
  [
    {:wardrik_triggers, "~> 0.1.0-rc.4"}
  ]
end
```

## Start triggers

Set `ANTHROPIC_API_KEY` before starting IEx. In a fresh session:

```elixir
Mix.install([
  {:wardrik_triggers, "~> 0.1.0-rc.4"},
  {:wardrik_core, "~> 0.1.0-rc.4"},
  {:wardrik_vault, "~> 0.1.0-rc.2"}
])

defmodule MyApp.Triggered do
  @behaviour WardrikTriggers.Target

  alias WardrikTriggers.Target.{Ask, Fired, Secret}

  @impl true
  def ask(%Ask{agent: id, prompt: prompt, trigger: trigger, overlap: overlap}, _opts) do
    case WardrikCore.whereis(id) do
      nil ->
        :no_agent

      agent ->
        case {overlap, WardrikCore.status(agent)} do
          {:queue, _status} -> asked(agent, prompt, trigger)
          {_overlap, :idle} -> asked(agent, prompt, trigger)
          {:settle, :waiting} -> settled(agent, prompt, trigger)
          {_overlap, _busy} -> :busy
        end
    end
  end

  defp settled(agent, prompt, trigger) do
    :ok = WardrikCore.interrupt(agent)
    asked(agent, prompt, trigger)
  end

  defp asked(agent, prompt, trigger) do
    :ok = WardrikCore.ask(agent, prompt, %{trigger: trigger})
    :asked
  end

  @impl true
  def fired(%Fired{}, _opts), do: :ok

  @impl true
  def resolve_secret(%Secret{name: name}, _opts) do
    case WardrikVault.fetch(MyApp.Vault, %WardrikCore.Principal{id: "acme"}, name,
           kind: :signing_secret
         ) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> :error
    end
  end
end

store = WardrikStore.ETS.new(name: MyApp.Store)

children = [
  {WardrikStore, store},
  {WardrikVault, name: MyApp.Vault, store: store, keys: [WardrikVault.generate_key()]},
  {WardrikCore, backend: {WardrikStore.Durable, store: store}},
  {WardrikTriggers, name: MyApp.Triggers, store: store, target: {MyApp.Triggered, []}}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, _agent} =
  WardrikCore.start_agent(agent_id: "agt_digest", model: "anthropic:claude-haiku-4-5")

:ok =
  WardrikTriggers.put(MyApp.Triggers, "agt_digest", [
    %{"name" => "daily", "every" => "0 9 * * *", "prompt" => "Write today's update."}
  ])
```

The target implements message delivery, overlap handling, and webhook-secret lookup. See `WardrikTriggers.Target`.

## Change triggers

```elixir
:ok =
  WardrikTriggers.put(MyApp.Triggers, "agt_digest", [%{"every" => "@daily", "prompt" => "Hi"}])

{:ok, _trigger} =
  WardrikTriggers.set(MyApp.Triggers, "agt_digest", %{
    "name" => "weekly",
    "every" => "@weekly",
    "prompt" => "Recap"
  })

:ok = WardrikTriggers.remove(MyApp.Triggers, agent_id: "agt_digest", name: "weekly")

WardrikTriggers.list(MyApp.Triggers, "agt_digest")

# => [{%WardrikTriggers.Trigger{name: "trigger-1", every: "@daily", ...}, ~U[2026-11-03 00:00:00Z]}]
```

Every key a trigger takes is in `WardrikTriggers.Trigger`.

## Feeds

- A trigger with `feed` asks only when the feed has entries it hasn't seen. The prompt lists up to 20.
- The first run only records what the feed holds.

## Webhooks

Continue in the same session to seal a signing secret and configure a webhook trigger:

```elixir
{:ok, _version} =
  WardrikVault.put(
    MyApp.Vault,
    %WardrikVault.Secret{
      principal: %WardrikCore.Principal{id: "acme"},
      name: "ISSUES_HOOK_SECRET",
      value: "example-hook-secret"
    }, kind: :signing_secret)

{:ok, _trigger} =
  WardrikTriggers.set(MyApp.Triggers, "agt_digest", %{
    "name" => "issues",
    "webhook" => %{"secret" => "${ISSUES_HOOK_SECRET}"},
    "prompt" => "Summarize the issue in this webhook."
  })
```

Use a secret generated for your service in production.

Plug router fragment: add `:plug` to your application dependencies.
Pass each request's raw body and headers to `deliver/2`. In a `Plug.Router`:

```elixir
post "/hooks/:agent/:trigger" do
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  request = %{body: body, headers: Map.new(conn.req_headers)}

  case WardrikTriggers.deliver(MyApp.Triggers, agent_id: agent, name: trigger, request: request) do
    :ok -> send_resp(conn, 202, "")
    {:error, :not_found} -> send_resp(conn, 404, "")
    {:error, _busy} -> send_resp(conn, 503, "")
  end
end
```

- Read the body before `Plug.Parsers` does. A signature covers the exact bytes.
- A request that fails to verify returns `{:error, :not_found}`. See `WardrikTriggers.Webhook`.
- Each request is asked about once, keyed by `Idempotency-Key`, `webhook-id`, or its body.

## In a cluster

Every node runs triggers. Each run happens once, on the node that claims it in the store.

## Telemetry

- `[:wardrik_triggers, :fired]` after every run. Metadata: `:agent_id`, `:trigger`, `:status`.

## License

Apache-2.0
