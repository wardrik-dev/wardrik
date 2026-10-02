# Wardrik

An agent runtime built on OTP. Agents are processes, delegation is a function
call, and everything an agent does publishes to one event stream you can
subscribe to and watch.

This is Wardrik's core. It runs agents and ships the contracts their tools,
hooks, credentials and stores implement, and no tools of its own. The
[packages](../../README.md#packages) beside it add those, and the
[daemon](../wardrik_daemon) puts them together behind one command.

## Installation

```elixir
def deps do
  [
    {:wardrik, "~> 0.1.0"},
    {:ekv, "~> 0.4.3"}
  ]
end
```

Wardrik starts with its application and keeps its store on each node's disk
through EKV. EKV is optional: an application that keeps the store elsewhere
leaves it out and never compiles its SQLite NIF. To keep it in an S3 bucket,
add [wardrik_s3](../wardrik_s3) and name the bucket:

```elixir
# config/runtime.exs
config :wardrik, Wardrik.Store,
  adapter: WardrikS3.Store,
  bucket: "wardrik",
  endpoint: "https://<account>.r2.cloudflarestorage.com",
  region: "auto",
  access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
  secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY")
```

To keep it in your own Postgres, add [wardrik_ecto](../wardrik_ecto), start
Wardrik after your repo, and create its table from a migration of your own:

```elixir
# config/config.exs
config :wardrik, start: :host
config :wardrik, Wardrik.Store, adapter: WardrikEcto.Store, repo: MyApp.Repo

# lib/my_app/application.ex
children = [MyApp.Repo, Wardrik, MyAppWeb.Endpoint]

# priv/repo/migrations/20260926000000_add_wardrik.exs
defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: WardrikEcto.Migration.up(version: 1)
  def down, do: WardrikEcto.Migration.down(version: 1)
end
```

## Agents

An agent is named by a key that says who it works for, and lives in the
fleet: one process for that key anywhere in the cluster, restarted on another
node when its own is lost.

```elixir
key = Wardrik.Fleet.key("assistant", org: current_org, user: current_user)

{:ok, _pid} = Wardrik.Fleet.spawn(key, config: Wardrik.LLM.Config.new(system: "You answer briefly."))
:ok = Wardrik.Event.Bus.subscribe(key)
:ok = Wardrik.Agent.ask(key, "What changed this week?")
```

`ask/2` returns at once. The agent takes its messages one turn at a time, and
what it does arrives as `Wardrik.Event`s: the text as it streams, each tool
call, and how each turn ended. `Wardrik.Agent.snapshot/1` gives a client that
attaches mid-turn what it missed.

## Tools

A tool implements `Wardrik.Tool`:

```elixir
defmodule MyApp.Ping do
  @behaviour Wardrik.Tool

  @impl true
  def tool do
    ReqLLM.Tool.new!(
      name: "ping",
      description: "Check whether a host answers.",
      parameter_schema: [host: [type: :string, required: true, doc: "Host to reach"]],
      callback: {__MODULE__, :run}
    )
  end

  def run(%{host: host}), do: Wardrik.Tool.Result.ok(%{"reachable" => reachable?(host)})
end

Wardrik.LLM.Config.new(tools: [MyApp.Ping])
```

Give a callback as `{module, function}` rather than an anonymous function:
a config is written to the store and read back on whichever node runs the
agent next, and a function cannot travel that way.

Modules belong to their package, so they only need to say what sets them
apart inside it. A tool's name is different: the model sees every tool's name
in one flat list, so it has to say everything on its own. `WardrikBrave.WebSearch`
is the tool `web_search`, and `WardrikResearch.Deep` is `deep_research`. Two
tools with the same name in one config collide, so pick names that are
specific.

A workflow is a `Wardrik.Workflow.Step`, and becomes a tool the same way when
an agent should be able to call it:

```elixir
defmodule MyApp.Nightly do
  @behaviour Wardrik.Tool
  @behaviour Wardrik.Workflow.Step

  @impl Wardrik.Tool
  def tool do
    Wardrik.Workflow.as_tool(__MODULE__,
      name: "nightly",
      description: "Summarise everything that changed since a date.",
      parameter_schema: [since: [type: :string, required: true, doc: "ISO date"]]
    )
  end

  @impl Wardrik.Workflow.Step
  def run(%{since: since}, scope, _opts) do
    scope
    |> Wardrik.Workflow.fan_out(repos(), fn repo, branch ->
      Wardrik.Subagent.run(branch, "What changed in #{repo} since #{since}?", except_tools: ["nightly"])
    end)
    |> report()
  end
end
```

`Wardrik.Subagent.run/3` delegates one bounded task to another agent and
returns its answer. It takes `:name`, `:system`, `:tools`, `:except_tools`,
`:model` and `:config`, so a workflow says who does the work it hands off, and
what they can use, without reaching into a scope or a config. Its events land
in the caller's stream, under a span of their own.

A persona is the config's `:system`. It is put before every turn rather than
kept in the conversation, so changing it changes the agent, and a delegate's
persona never leaks into its caller's history.

## Seams

Core runs agents. Who an agent works for, which of its calls may run, and
which model a call lands on and who pays for it are seams your application
fills in. Each is inert until you give it something, so an application that
needs none of them configures none of them.

```elixir
Wardrik.Fleet.spawn(key,
  config: config,
  hooks: hooks,                    # may this call run?
  dispatch: MyApp.Gateway,         # which model, whose key, what did it cost?
  credentials: WardrikVault,       # where a secret a tool names comes from
  ledger: Wardrik.Ledger.Store,    # which calls already ran, if the turn is lost
  timeout: :timer.minutes(10)
)
```

| Seam | What it decides |
| --- | --- |
| `:org`, `:user` | Who the work is for. They are written into the agent's key, as `acme/@jon/assistant`, and carried on every `Wardrik.Scope`. Every agent has an org: a key without one is in `config :wardrik, Wardrik.Fleet, org: ...`. The key appears in every event and store key, so give a user as an id rather than an email address. |
| `:hooks` | A list of `Wardrik.Hook`s, each handed every tool call and model call before it happens. A hook may deny a call, ask a person about it, or leave it be, and the strictest answer wins. |
| `:dispatch` | A `Wardrik.LLM.Dispatch`, which decides what a model call actually is just before it is made, and hears what it cost. |
| `:credentials` | A `Wardrik.Credential` resolver, which finds the secret a tool names for the user it is working for. See [wardrik_vault](../wardrik_vault). |
| `:ledger` | A `Wardrik.Ledger`, which records each tool call before it runs. See [A turn lost part way](#a-turn-lost-part-way). |
| `:timeout` | A deadline for each turn. Work under it can narrow it, never widen it. |

The same agent written down is a `Wardrik.Agent.Spec`, which holds no process
and no function. `Wardrik.Fleet.put/1` starts the agent a spec describes, or
gives the running one what the spec says now:

```elixir
spec = Wardrik.Agent.Spec.new(name: "assistant", org: current_org, config: config, hooks: hooks)
{:ok, pid} = Wardrik.Fleet.put(spec)
```

### Hooks

A hook is a module with `init/1` and `call/2`, the way a plug is, and a
`Wardrik.Call` is what it is handed:

```elixir
defmodule MyApp.NoFridayDeploys do
  @behaviour Wardrik.Hook
  import Wardrik.Call

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(%Wardrik.Call{target: %Wardrik.Call.Tool{name: "deploy"}} = call, _value) do
    if friday?(), do: deny(call, "No deploys on a Friday."), else: call
  end

  def call(call, _value), do: call
end

hooks = [Wardrik.Hook.new("fridays", MyApp.NoFridayDeploys, timezone: "Europe/London")]
```

What `init/1` returns is plain data, so a hook travels with its agent to
whichever node holds it. [wardrik_policy](../wardrik_policy) turns a policy
written as data into hooks.

A hook that asks a person **parks** the turn: nothing runs, nothing is added
to the conversation, and the agent waits until someone answers.

```elixir
Wardrik.Agent.parked("acme/@jon/assistant")
#=> [{%{id: "call_1", name: "deploy", arguments: %{}}, "This ships to production."}]

Wardrik.Agent.resume("acme/@jon/assistant", %{"call_1" => :approve})
```

An approval, a credential the user still has to connect, and a call a person
has to make somewhere else all park the same way, so there is one thing to
handle rather than three. An agent given new hooks while it waits has them
decide what it waits on: a call they allow goes ahead, one they deny is
refused, and one they ask about waits on their question instead.

### Stopping things

```elixir
Wardrik.Agent.interrupt("acme/@jon/assistant")                      # the whole turn
Wardrik.LLM.ToolRunner.kill_call("acme/@jon/assistant", "call_1")   # one tool call
Wardrik.LLM.ToolRunner.in_flight("acme/@jon/assistant")             # what could be stopped
```

A killed call is answered with an error, so the model is never left waiting
on a call nobody answered.

### A history that grows

An agent that runs for weeks keeps adding to one conversation. Before the
conversation outgrows what the model can read, the agent summarises the
older part with its own model and keeps the most recent part word for word.
By default it compacts at 60% of the model's context window and keeps the
last 25%:

```elixir
Wardrik.LLM.Config.new(compaction: Wardrik.Compaction.new(at: 0.5, keep: 0.2))
Wardrik.LLM.Config.new(compaction: nil)   # never
```

It happens between turns and is reported as `{:context_compacted, stats}`. The
summary is a model call like any other, so a budget counts it.

### A turn lost part way

A turn hands its agent each batch of tool calls before running any of them,
and the agent writes the batch to the store first. A turn whose node is lost
comes back replaying from that batch, with the same calls, rather than asking
the model again.

With a `Wardrik.Ledger` on the scope, each call is claimed before it runs and
settled after. A replay then answers a call that already ran with what it
returned, and parks one that began and never finished for a person to decide:

```elixir
Wardrik.Fleet.spawn(key, config: config, ledger: Wardrik.Ledger.Store)
```

A tool with an effect outside Wardrik passes
`Wardrik.Ledger.idempotency_key/2` to the system it calls, so that system
does not repeat the effect either.

### Failures

`Wardrik.Failure.classify/1` sorts a turn's error into `:transient`,
`:ceiling` or `:bug`, so you know whether trying again could help. Anything
it does not recognise is a `:bug`, because a retry loop that assumes
otherwise spends real money finding out.

## Testing

Core ships what a suite built on it needs, under `Wardrik.Test`.
`Wardrik.Test.start/1` starts ExUnit once the runtime is ready, so a
`test_helper.exs` is one line. `Wardrik.Test.scope/1` builds the scope a turn
runs under, and `Wardrik.Test.call/4` runs one tool call through the steps a
turn runs it, hooks and ledger included:

```elixir
scope = Wardrik.Test.scope(tools: [MyApp.Tools.Ping], hooks: hooks)
assert %Wardrik.Call{state: :done, result: {:ok, _}} = Wardrik.Test.call(scope, "ping", %{host: "a"})
```

`Wardrik.Test.Fleet` starts an agent under a key of each test's own and
removes it after, `Wardrik.Test.LLMStub` answers turns with canned responses
through Mimic, and `Wardrik.Test.Durable` and `Wardrik.Store.Conformance`
check a store adapter of your own.
