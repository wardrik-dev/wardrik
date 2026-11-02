# WardrikTriggers

Asks agents something on a clock, when a feed has new entries, or when a service sends a webhook.

```elixir
WardrikTriggers.put(MyApp.Triggers, "agt_digest", [
  %{"name" => "daily", "every" => "0 9 * * *", "prompt" => "Write today's update."},
  %{"name" => "rivals", "every" => "6h", "feed" => "https://rivalco.example/changelog.rss", "prompt" => "What changed?"},
  %{"name" => "issues", "webhook" => %{"secret" => "${ISSUES_HOOK_SECRET}"}, "prompt" => "Triage it."}
])
```

With [Wardrik](https://hexdocs.pm/wardrik), triggers are part of an agent's definition and all of
this is set up for you. See [Trigger agents](https://hexdocs.pm/wardrik/triggers.html).

## Install

```elixir
def deps do
  [
    {:wardrik_triggers, "~> 0.1.0-rc.1"}
  ]
end
```

## Start it

Add `WardrikTriggers` to your supervision tree. It needs a
[WardrikStore](https://hexdocs.pm/wardrik_store) to keep triggers in, and a
`WardrikTriggers.Target` to ask your agents.

```elixir
store = WardrikStore.ETS.new(name: MyApp.Store)

children = [
  {WardrikStore, store},
  {WardrikVault, name: MyApp.Vault, store: store, keys: [System.fetch_env!("VAULT_KEY")]},
  {WardrikCore, backend: {WardrikStore.Durable, store: store}},
  {WardrikTriggers, name: MyApp.Triggers, store: store, target: {MyApp.Triggered, []}}
]
```

Here the agents are [WardrikCore](https://hexdocs.pm/wardrik_core)'s, and webhook secrets are kept
in a [WardrikVault](https://hexdocs.pm/wardrik_vault).

### Options

  * `:name` - required. What you pass to every other function.
  * `:store` - required. The `WardrikStore` triggers are kept in.
  * `:target` - required. A `WardrikTriggers.Target`, as `{module, config}`.
  * `:req_options` - `Req` options for reading feeds. `[]` unless set.
  * `:reconcile` - milliseconds between each node reading every trigger again, or `:infinity`.
    One minute unless set.

### The target

The target asks the agent, hears how each run went, and resolves webhook secrets:

```elixir
defmodule MyApp.Triggered do
  @behaviour WardrikTriggers.Target

  alias WardrikTriggers.Target.{Ask, Fired, Secret}

  require Logger

  @impl true
  def ask(%Ask{agent: id} = ask, _opts) do
    case WardrikCore.whereis(id) do
      nil -> :no_agent
      agent -> asked(agent, ask)
    end
  end

  @impl true
  def fired(%Fired{agent: id, trigger: trigger, status: status}, _opts),
    do: Logger.info("#{id} ran #{trigger}: #{status}")

  @impl true
  def resolve_secret(%Secret{name: name}, _opts) do
    case WardrikVault.fetch(MyApp.Vault, %WardrikCore.Principal{id: "acme"}, name) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> :error
    end
  end

  defp asked(agent, %Ask{prompt: prompt, trigger: trigger, overlap: overlap}) do
    if overlap == :skip and WardrikCore.status(agent) != :idle do
      :busy
    else
      :ok = WardrikCore.ask(agent, prompt, %{trigger: trigger})
      :asked
    end
  end
end
```

Every run also emits `[:wardrik_triggers, :fired]` telemetry, with `agent_id`, `trigger` and
`status` in its metadata.

## Give an agent triggers

`put/3` replaces an agent's triggers. A trigger is a map with string keys, as an agent file
writes it.

```elixir
{:ok, _agent} = WardrikCore.start_agent(agent_id: "agt_digest", model: "anthropic:claude-haiku-4-5")
{:ok, _vsn} =
  WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{
    principal: %WardrikCore.Principal{id: "acme"},
    name: "ISSUES_HOOK_SECRET",
    value: "s3cret"
  })

:ok =
  WardrikTriggers.put(MyApp.Triggers, "agt_digest", [
    %{"name" => "daily", "every" => "0 9 * * *", "timezone" => "America/Los_Angeles", "prompt" => "Write today's update."},
    %{"name" => "rivals", "every" => "6h", "feed" => "https://rivalco.example/changelog.rss", "prompt" => "What changed?"},
    %{"name" => "issues", "webhook" => %{"secret" => "${ISSUES_HOOK_SECRET}"}, "prompt" => "Triage it."}
  ])
```

`set/3` and `remove/2` change one trigger. `list/2` returns each trigger with its next run, `nil`
for a webhook:

```elixir
WardrikTriggers.list(MyApp.Triggers, "agt_digest")
#=> [
#=>   {%WardrikTriggers.Trigger{name: "daily", every: "0 9 * * *", timezone: "America/Los_Angeles", ...},
#=>    ~U[2026-10-24 16:00:00Z]},
#=>   {%WardrikTriggers.Trigger{name: "issues", webhook: %{secret: "${ISSUES_HOOK_SECRET}", verify: :shared}, ...}, nil},
#=>   ...
#=> ]
```

### Trigger keys

A trigger has `every` or `webhook`, and `prompt` or `prompt_file`.

| Key | Means | Unless set |
| --- | --- | --- |
| `every` | a cron expression, as `0 9 * * 1` or `@daily`, or an interval of at least a minute, as `30m`, `2h` or `1d` | |
| `webhook` | `%{"secret" => "${NAME}", "verify" => "shared"}`; `verify` is `shared` or `standard`. In place of `every` | `verify` is `shared` |
| `prompt` | what the agent is asked | |
| `prompt_file` | a file the agent is told to read and follow, in place of `prompt` | |
| `name` | the trigger's name; no `/`, `:` or whitespace | `trigger-1`, `trigger-2`, ... by position |
| `timezone` | the zone a cron expression is read in, as `Europe/Berlin` | `Etc/UTC` |
| `overlap` | `skip` leaves a busy agent alone; `queue` asks it anyway | `skip`, or `queue` for a webhook |
| `missed` | `run_once` runs once after missed runs; `skip` drops them | `run_once` |
| `jitter` | up to this many seconds added to each run | `0` |
| `feed` | an RSS or Atom feed URL, or a list of them | |

## On a clock

A cron expression is read in `timezone`. A time skipped by a clock change runs at the first
instant after the gap. A time repeated by a clock change runs on its first pass only. An interval
counts from when the trigger was set or last ran.

A run more than a minute late runs once, however many runs were missed. With `missed: skip` it
doesn't run, and its status is `:missed`.

## Watching a feed

A trigger with `feed` asks only when a feed has entries it hasn't seen. The prompt lists up to 20
of them.

  * The first run only records what each feed holds. It asks nothing.
  * An unchanged feed (`304`) has nothing new.
  * A run fails only when no feed can be read.

## Receiving a webhook

Pass each request to `deliver/2` with its raw body and headers. In a `Plug.Router`:

```elixir
post "/hooks/:org/:name/:trigger" do
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  request = %{body: body, headers: Map.new(conn.req_headers), path_secret: nil}

  delivery = [agent_id: "#{org}/#{name}", name: trigger, request: request]

  case WardrikTriggers.deliver(MyApp.Triggers, delivery) do
    :ok -> send_resp(conn, 202, "")
    {:error, :not_found} -> send_resp(conn, 404, "")
    {:error, _busy} -> send_resp(conn, 503, "")
  end
end
```

Read the body before `Plug.Parsers` does. A signature covers the exact bytes.
[WardrikHTTP](https://hexdocs.pm/wardrik_http) serves this route for Wardrik.

  * `verify: shared` - the request presents the secret as a bearer token, or as `path_secret`.
  * `verify: standard` - the request is signed as
    [Standard Webhooks](https://www.standardwebhooks.com/) specifies.

The target resolves the secret that `${NAME}` names. A request that fails to verify returns
`{:error, :not_found}`. Each request is asked about once, keyed by its `Idempotency-Key`, its
`webhook-id`, or a hash of its body.

## In a cluster

Every node runs triggers. A node claims a run by moving the trigger's next run forward in the
store, conditional on the version it read. So each run happens once in the cluster, and when a node
is lost another picks up its triggers.

## License

Apache-2.0
