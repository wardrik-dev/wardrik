# Tars

An agent runtime built on OTP. Agents are processes, delegation is a function
call, and everything one agent does publishes to one event stream you can
subscribe to and watch.

Core has no dependencies you did not ask for and ships no tools and no
workflows. What it ships is the contracts and the machinery that runs them.

## Packages

Anything that reaches the outside world, or that encodes work specific to one
deployment, lives in a package rather than in core. A package is named for its
subject and never defines modules under `Tars.`:

```elixir
Tars.LLM.Config.new(tools: [TarsBrave.WebSearch, TarsResearch.Deep])
```

| | |
| --- | --- |
| **`Tars.*`** | core |
| **`Tars<Subject>`** | a package, for example `TarsBrave`, `TarsResearch` |

There is one list, `:tools`, because a workflow reaches an agent by being
callable, which makes it a tool. A workflow the agent cannot call is a
function the deployment calls itself and does not need registering.

### Naming

**The module is qualified by its package; the tool name is not.** A module only
has to say what distinguishes it inside its package, since the package name is
right there. A tool name is a bare string in a flat namespace the model sees,
so it carries everything.

```
TarsBrave.WebSearch      tool "web_search"       "brave" is ours, not the model's
TarsResearch.Deep        tool "deep_research"    "research" is the model's, so the tool re-adds it
```

Tool names are flat per config, so two packages shipping the same tool name
collide. Pick a specific one.

### Writing one

A tool implements `Tars.Tool`:

```elixir
defmodule MyPack.Ping do
  @behaviour Tars.Tool

  @impl true
  def tool do
    ReqLLM.Tool.new!(
      name: "ping",
      description: "Check whether a host answers.",
      parameter_schema: [host: [type: :string, required: true, doc: "Host to reach"]],
      callback: {__MODULE__, :run}
    )
  end

  def run(%{host: host}), do: Tars.Tool.Result.ok(%{"reachable" => reachable?(host)})
end
```

A workflow implements `Tars.Workflow.Step`, and implements `Tars.Tool` as well
if an agent should be able to call it:

```elixir
defmodule MyPack.Nightly do
  @behaviour Tars.Tool
  @behaviour Tars.Workflow.Step

  @impl Tars.Tool
  def tool do
    Tars.Workflow.as_tool(__MODULE__,
      name: "nightly",
      description: "Summarise everything that changed since a date.",
      parameter_schema: [since: [type: :string, required: true, doc: "ISO date"]]
    )
  end

  @impl Tars.Workflow.Step
  def run(%{since: since}, scope, _opts) do
    scope
    |> Tars.Workflow.fan_out(repos(), fn repo, branch ->
      Tars.Subagent.run(branch, "What changed in #{repo} since #{since}?", except_tools: ["nightly"])
    end)
    |> report()
  end
end
```

`as_tool/2` is an ordinary function, so a workflow whose name and schema are
only known at runtime is built the same way. `Tars.Subagent.run/3` takes
`:name`, `:system`, `:tools`, `:except_tools`, `:model` and `:config`, so a
workflow never has to reach into a `Tars.Scope` or a `Tars.LLM.Config` to
decide who the work it delegates is, or what it can do.

A persona is `:system` on the config, prepended to every turn rather than
stored in the conversation, so changing it changes the agent and a subagent's
persona never leaks into the caller's history.

Prefer an MFA callback over an anonymous function for anything a config holds,
so it survives being named by a config that crosses a node boundary.

### Living in this repo

Packages start here, under `lib/<package>/` with tests mirrored at
`test/<package>/`, and move out when there is a reason to. While a package is
in-repo its settings nest under the application that exists:

```elixir
config :tars, TarsBrave, api_key: System.fetch_env!("BRAVE_API_KEY")
```

After extraction that becomes `config :tars_brave, api_key: ...`. Each package
documents its own extraction in its moduledoc. Nothing in `Tars` changes
either way, because core names no tool and no workflow.

## Seams

Core runs agents. Everything that decides *who* an agent is working for, *what*
it may do, and *who pays for it* is a seam a host reaches through, so a
deployment that needs none of them configures none of them.

```elixir
Tars.Agent.Supervisor.start(:assistant,
  config: config,
  user: current_user,        # whatever your app's user is
  org: current_org,
  policy: MyApp.Policy,      # may this tool call run?
  dispatch: MyApp.Gateway,   # which model, whose key, what did it cost?
  timeout: :timer.minutes(10)
)
```

| | |
| --- | --- |
| **`:user`, `:org`** | carried on `Tars.Scope`, the way a Phoenix scope carries them. Your own structs; core never reads inside them and never puts them in an event. |
| **`:policy`** | a `Tars.Policy`. Asked about every tool call before it runs, and answers `:allow`, `{:deny, reason}` or `{:ask, prompt}`. |
| **`:dispatch`** | a `Tars.LLM.Dispatch`. `admit/2` decides what the call actually is, immediately before it is made; `settle/3` reports what it cost. |
| **`:timeout`** | a deadline on the scope. Work can narrow it and never widen it. |

A policy that asks **parks** the turn: nothing runs, nothing is appended to the
conversation, and the agent waits.

```elixir
Tars.Agent.parked(:assistant)
#=> [{%{id: "call_1", name: "deploy", arguments: %{}}, "This ships to production."}]

Tars.Agent.resume(:assistant, %{"call_1" => :approve})
```

Approval, a credential that needs connecting, and a call a person has to run
elsewhere are all the same shape, so there is one mechanism rather than three.

### Stopping things

```elixir
Tars.Agent.interrupt(:assistant)                      # the whole turn
Tars.LLM.ToolRunner.kill_call(:assistant, "call_1")   # one tool call
Tars.LLM.ToolRunner.in_flight(:assistant)             # what could be stopped
```

A killed call is answered with an error result, so the model is never left with
a call nobody answered.

### Failures

`Tars.Failure.classify/1` sorts a turn's error into `:transient`, `:ceiling` or
`:bug`, so a caller knows whether trying again is worth anything. Anything
unrecognised is a `:bug` — a retry loop that assumes otherwise spends real
money finding out.

## Installation

```elixir
def deps do
  [
    {:tars, "~> 0.1.0"}
  ]
end
```
