# Wardrik core

An agent runtime built on OTP. Agents are processes, delegation is a function
call, and everything an agent does publishes to one event stream you can
subscribe to and watch.

This is Wardrik's core. It runs agents and ships the contracts their tools,
hooks, credentials and stores implement, and no tools of its own. The
[packages](../../README.md#packages) beside it add those, and the
[daemon](../wardrik_daemon) puts them together behind one command.

An application embedding Wardrik depends on [wardrik](../wardrik) instead,
whose `Wardrik` starts this with the store and the packages around it. This
package is for a host that puts its own tree together, as the daemon does.

## Installation

```elixir
def deps do
  [
    {:wardrik_core, "~> 0.1.0"},
    {:ekv, "~> 0.4.3"}
  ]
end
```

Nothing starts with the application. Start the store, then core on a host
keeping everything in it:

```elixir
store = WardrikStore.new(adapter: WardrikStore.EKV, data_dir: "/var/lib/my_app/wardrik")

children = [
  {WardrikStore, store},
  {Wardrik.Core, host: Wardrik.Host.new(store: store)}
]
```

EKV keeps the store on each node's disk. It is optional: an application that
keeps the store elsewhere, in Postgres or in a bucket through
[wardrik](../wardrik)'s adapters, leaves it out and never compiles its SQLite
NIF. [The store](guides/store.md) lists the adapters, and
[Schemas](guides/protocol.md) the JSON Schemas core ships in `priv/`.

## Agents

An agent is named by a `Wardrik.AgentID` that says who it works for, and
lives in the fleet: one process for that ID anywhere in the cluster, restarted
on another node when its own is lost.

```elixir
id = Wardrik.AgentID.new!("assistant", org: current_org, user: current_user)

{:ok, _pid} = Wardrik.Fleet.spawn(id, config: Wardrik.LLM.Config.new(system: "You answer briefly."))
:ok = Wardrik.Event.Bus.subscribe(id)
:ok = Wardrik.Agent.ask(id, "What changed this week?")
```

An ID is `acme/assistant` for an org's own agent, `acme/@jon/assistant` for
one that works for a user, and either with an external ID after it, such as a
thread in a chat, where one agent answers for many. The fleet is listed,
watched and stopped by `Wardrik.AgentID.Prefix`.

`ask/2` returns at once. The agent takes its messages one turn at a time, and
what it does arrives as `Wardrik.Event`s: the text as it streams, each tool
call, and how each turn ended. `Wardrik.Agent.snapshot/1` gives a client that
attaches mid-turn what it missed.

Where several people talk to one agent, as in a chat room, each message names
who sent it, and the model reads that ahead of the text:

```elixir
:ok = Wardrik.Agent.ask(id, "Reconcile last week.", sender: Wardrik.Principal.new(:channel, "slack/U024BE7LH", name: "Maria Chen"))
```

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

A tool that needs to know who it works for, a credential, or a way to report
progress is built with `Wardrik.Tool.new!/1` and handed a `Wardrik.Tool.Context`
with its arguments. What holds for every call to it, such as being gated or
needing a credential, is its `annotations/1`; see `Wardrik.Tool.Annotations`.

Modules belong to their package, so they only need to say what sets them
apart inside it. A tool's name is different: the model sees every tool's name
in one flat list, so it has to say everything on its own. `WardrikBrave.WebSearch`
is the tool `web_search`, and `WardrikResearch.Deep` is `deep_research`. Two
tools with the same name in one config collide, so pick names that are
specific.

`Wardrik.Subagent.run/3` delegates one bounded task to another agent and
returns its answer. It takes `:name`, `:system`, `:tools`, `:except_tools`,
`:model` and `:config`, so a tool says who does the work it hands off, and
what they can use, without reaching into a run or a config. Its events land
in the caller's stream, under a span of their own.

A persona is the config's `:system`. It is put before every turn rather than
kept in the conversation, so changing it changes the agent, and a delegate's
persona never leaks into its caller's history.

## Seams

Core runs agents. Who an agent works for, which of its calls may run, and
which model a call lands on and who pays for it are seams your application
fills in. Each is inert until you give it something, so an application that
needs none of them configures none of them. Who the work is for is the
agent's ID, which every `Wardrik.Run` names: it appears in every event and
store key, so give a user as an id rather than an email address.

```elixir
Wardrik.Fleet.spawn(id,
  config: config,
  hooks: hooks,                    # may this call run?
  ledger: %Wardrik.Ledger.Store{}, # which calls already ran, if the turn is lost
  timeout: :timer.minutes(10)
)
```

| Seam | What it decides |
| --- | --- |
| `:hooks` | A list of `Wardrik.Hook`s, each handed every tool call and model call before it happens. A hook may deny a call, ask a person about it, or leave it be, and the strictest answer wins. Each hears what a call did once it is made. |
| `:ledger` | A `Wardrik.Ledger`, which records each tool call before it runs. See [A turn lost part way](#a-turn-lost-part-way). |
| `:timeout` | A deadline for each turn. Work under it can narrow it, never widen it. |

Which model a call lands on and who pays for it is the host's dispatch, the
same for every agent; see [The host](#the-host).

Every call, to a tool or a model, passes the seams in one order, as
`Wardrik.Call.Pipeline` sets out: the hooks decide it, the ledger claims it
and its credentials are resolved, or the dispatch admits it, it is made, and
the ledger, the dispatch and the hooks hear how it ended.

The same agent written down is a `Wardrik.Agent.Spec`, which holds no process
and no function. `Wardrik.Fleet.put/1` starts the agent a spec describes, or
gives the running one what the spec says now:

```elixir
spec = Wardrik.Agent.Spec.new(name: "assistant", org: current_org, config: config, hooks: hooks)
{:ok, pid} = Wardrik.Fleet.put(spec)
```

### Hooks

A hook is a module with `init/1` and `call/2`, the way a plug is. It is
handed a `Wardrik.Call` and says what it makes of it: `:pass`, `:allow`,
`{:ask, prompt}` or `{:deny, reason}`.

```elixir
defmodule MyApp.NoFridayDeploys do
  @behaviour Wardrik.Hook

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(%Wardrik.Call{target: %Wardrik.Call.Tool{name: "deploy"}}, %{timezone: tz}) do
    if friday?(tz), do: {:deny, "No deploys on a Friday."}, else: :pass
  end

  def call(_call, _value), do: :pass
end

hooks = [Wardrik.Hook.new("fridays", MyApp.NoFridayDeploys, timezone: "Europe/London")]
```

What `init/1` returns is plain data, so a hook travels with its agent to
whichever node holds it. [wardrik](../wardrik)'s `WardrikPolicy` turns a policy
written as data into hooks.

A hook that asks a person **parks** the turn: nothing runs, nothing is added
to the conversation, and the agent waits until someone answers.

```elixir
Wardrik.Agent.parked(id)
#=> [{%{id: "call_1", name: "deploy", arguments: %{}}, "This ships to production."}]

Wardrik.Agent.resume(id, %{"call_1" => :approve})
```

An approval, a credential the user still has to connect, and a call a person
has to make somewhere else all park the same way, so there is one thing to
handle rather than three. An agent given new hooks while it waits has them
decide what it waits on: a call they allow goes ahead, one they deny is
refused, and one they ask about waits on their question instead.

### Stopping things

```elixir
Wardrik.Agent.interrupt(id)                      # the whole turn
Wardrik.LLM.ToolRunner.kill_call(id, "call_1")   # one tool call
Wardrik.LLM.ToolRunner.in_flight(id)             # what could be stopped
```

A killed call is answered with an error, so the model is never left waiting
on a call nobody answered.

### What people changed

A surface people act through records each change it makes, with who made
it, in one log for the whole cluster, beside each agent's own:

```elixir
:ok = Wardrik.Audit.record({:agent_forgotten, id}, Wardrik.Principal.new(:user, "jon"))
{:ok, changes} = Wardrik.Event.Log.read(:audit, starting_after: 0)
```

Changes are CloudEvents from `wardrik://local/audit`, kept as long as
agents' events are. `Wardrik.Audit` lists them.

### Exporting every log

`Wardrik.Event.Export` reads every log, the audit and each agent's, a removed
agent's included, on from a named cursor kept in the store. A page leaves the
cursor where it is until the reader moves it, so each event arrives at least
once, on any node and after any restart:

```elixir
{:ok, page} = Wardrik.Event.Export.read("siem", limit: 500)
:ok = ship(page.events)
:ok = Wardrik.Event.Export.advance("siem", page.next)
```

### A history that grows

An agent that runs for weeks keeps adding to one conversation. Before the
conversation outgrows what the model can read, the agent summarises the
older part with its own model and keeps the most recent part word for word.
By default it compacts at 60% of the model's context window and keeps the
last 25%:

```elixir
Wardrik.LLM.Config.new(history: {Wardrik.Compaction, Wardrik.Compaction.new(at: 0.5, keep: 0.2)})
Wardrik.LLM.Config.new(history: nil)   # never
```

It happens as a turn begins, before the messages it answers join the history,
and is reported as `{:context_compacted, stats}`. The summary is a model call
of the turn's like any other, so a budget counts it, and interrupting the turn
interrupts it. Compaction is the default `Wardrik.History`: a module of your
own can keep the history its way instead.

### A turn lost part way

A turn hands its agent each batch of tool calls before running any of them,
and the agent writes the batch to the store first. A turn whose node is lost
comes back replaying from that batch, with the same calls, rather than asking
the model again.

With a `Wardrik.Ledger` on the run, each call is claimed before it runs and
settled after. A replay then answers a call that already ran with what it
returned, and parks one that began and never finished for a person to decide,
as it does a call whose tool answers `{:in_doubt, reason}` because it cannot
say how the call ended:

```elixir
Wardrik.Fleet.spawn(id, config: config, ledger: %Wardrik.Ledger.Store{})
```

A tool with an effect outside Wardrik passes
`Wardrik.Ledger.Key.idempotency/2` to the system it calls, so that system
does not repeat the effect either.

### The host

What acting on the agents asks beyond one agent is the host's: where definitions are
kept, which accounts people connect, where the secrets tools and model
providers need come from, how tokens are made, where requests for triggers
go, what each principal may do, and what each model call actually is. A
`Wardrik.Host` names a value for each it offers, carrying that seam's own
settings, and the default of each it does not. It is handed
to `Wardrik.Core` as it starts, which hands it to every agent, and to each
surface the application starts after it, which builds its callers with it:

```elixir
host =
  Wardrik.Host.new(
    store: store,
    definitions: %MyApp.Definitions{store: store},
    credentials: WardrikVault.new(store: store, keys: [key]),
    grants: %MyApp.Grants{admins: ["maria"]},
    dispatch: %MyApp.Gateway{keys: keys}
  )

children = [
  {Wardrik.Core, host: host},
  {MyApp.Endpoint, host: host}
]

{:ok, caller} = Wardrik.Host.caller(host, principal: maria, subject: id)
:ok = Wardrik.Agent.decide(id, %{"call_1" => :approve}, caller)
```

Nothing of the host is kept on the node or with an agent. A node runs one
`Wardrik.Core`, since core's own processes are registered under their module
names; to run several on one machine, run several nodes.

### Retries

A model call that fails is asked again by the run's `Wardrik.LLM.Retry`:
`Wardrik.LLM.Retry.Backoff` unless the agent names another. It asks again
up to six times, after random waits that double from a second, and then
asks a person whether to try again. An answer with a 4xx status, but for
408, 425 and 429, goes to a person at once.

## Public modules

What a package may call of core is the modules below, and each package's
`.reach.exs` holds it to them: a call into any other `Wardrik.*` module fails
`mix reach.check --arch`. A module not listed is core's own, and changes
without notice.

| | Modules |
| --- | --- |
| Contracts a package implements, and what they are handed | `Wardrik.Tool`, `Wardrik.Tool.Context`, `Wardrik.Tool.Name`, `Wardrik.Tool.Result`, `Wardrik.Hook`, `Wardrik.Call`, `Wardrik.Call.Ask`, `Wardrik.Label`, `Wardrik.Run`, `Wardrik.Credential`, `Wardrik.Credentials`, `Wardrik.Definition`, `Wardrik.Definition.Read`, `Wardrik.Definitions`, `Wardrik.Connections`, `Wardrik.Connections.Owner`, `Wardrik.Tokens`, `Wardrik.Triggers`, `Wardrik.Grants`, `Wardrik.Servers` and the `None` of each, `Wardrik.Grants` and the `None` of each, `Wardrik.Servers.Key`, `Wardrik.Servers.Server`, `Wardrik.Connections.Connection`, `Wardrik.Tokens.Token`, `Wardrik.Ledger`, `Wardrik.Ledger.Key`, `Wardrik.Ledger.None`, `Wardrik.Ledger.Store` |
| Agents and the fleet | `Wardrik.Core`, `Wardrik.Host`, `Wardrik.AgentID`, `Wardrik.AgentID.Prefix`, `Wardrik.AgentID.Segment`, `Wardrik.Fleet`, `Wardrik.Fleet.Member`, `Wardrik.Agent`, `Wardrik.Agent.Spec`, `Wardrik.Agent.Snapshot`, `Wardrik.Grant`, `Wardrik.Principal`, `Wardrik.LLM.Config`, `Wardrik.LLM.Retry`, `Wardrik.LLM.Retry.Backoff`, `Wardrik.History`, `Wardrik.Compaction`, `Wardrik.TimeZone` |
| Who acts, and what `Wardrik` answers them | `Wardrik.Caller`, `Wardrik.Error`, `Wardrik.Resource`, `Wardrik.Agent.Message`, `Wardrik.Deployment.Nodes` |
| What people changed | `Wardrik.Audit` |
| Following what agents do | `Wardrik.Event`, `Wardrik.Event.Bus`, `Wardrik.Event.Export`, `Wardrik.Event.Log`, `Wardrik.Event.Log.Entry`, `Wardrik.Event.Codec.Value`, `Wardrik.Delegation`, `Wardrik.LLM.Message` |
| Inside a turn | `Wardrik.Subagent`, `Wardrik.LLM.Cost`, `Wardrik.LLM.Usage`, `Wardrik.UUID` |
| Testing | `Wardrik.Test` and the modules under it |

## Testing

Core ships what a suite built on it needs, under `Wardrik.Test`.
`Wardrik.Test.start/1` starts ExUnit once the runtime is ready, so a
`test_helper.exs` is one line. `Wardrik.Test.run/1` builds the run a turn
runs under, and `Wardrik.Test.call/4` runs one tool call through the steps a
turn runs it, hooks and ledger included:

```elixir
run = Wardrik.Test.run(tools: [MyApp.Tools.Ping], hooks: hooks)
assert %Wardrik.Call{state: :done, result: {:ok, _}} = Wardrik.Test.call(run, "ping", %{host: "a"})
```

`Wardrik.Test.Fleet` starts an agent under an ID of each test's own and
removes it after, `Wardrik.Test.LLMStub` answers turns with canned responses
through Mimic. A store adapter of your own is checked with
`WardrikStore.Conformance` and
`WardrikStore.Test.Durable`.
