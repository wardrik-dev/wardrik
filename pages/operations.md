# Operations

Everything people and programs do with agents is an operation. Each works the same from your
code, HTTP, Slack or a terminal.

## Setup

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.10"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer
  def authorize(_request, _opts), do: :ok
end

# Every agent works for Maria.
defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver
  def resolve(_request, _opts), do: {:ok, %Wardrik.Resolved{principal: Wardrik.principal("maria")}}
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []}
  )

scope = Wardrik.as(MyApp.AgentRuntime, "maria")
```

## As functions

Each operation is a function named by its ID. `agent.define` is `Wardrik.Agent.define/3`:

```elixir
{:ok, books} = Wardrik.Agent.define(scope, "agt_books", model: "anthropic:claude-haiku-4-5")

Wardrik.Agent.read(scope, books)
#=> {:ok, %Wardrik.Agent{id: "agt_books", status: :idle, node: "nonode@nohost", ...}}

Wardrik.Agents.list(scope)
#=> {:ok, [%Wardrik.Agent{id: "agt_books", ...}]}

Wardrik.Agent.cancel(scope, books)
#=> :ok

Wardrik.Agent.read(scope, "agt_ledger")
#=> {:error, %Wardrik.Error{type: :not_found, message: "There's no agent agt_ledger."}}
```

- The first argument is the scope.
- One path parameter comes next, as text or its struct: `Wardrik.Agent.read(scope, "agt_books")`.
- Two or more go in one keyword list with the input:
  `Wardrik.Agent.approve(scope, agent: "agt_books", interrupt: "toolu_01")`.
- The rest of the input is a keyword list. `conversation:` picks one of the agent's conversations.
- It returns a struct, a list of them, `:ok`, or `{:error, %Wardrik.Error{}}`.
- Streamed operations also have a `stream_` function. See [Events](events.md).

| Module | Operations |
| --- | --- |
| `Wardrik.Agent` | One agent: define, ask, read, decide, stop, forget, triggers, events, runs. |
| `Wardrik.Agents` | Many agents: list, cancel, forget. |
| `Wardrik.Interrupts` | Calls waiting on a person. |
| `Wardrik.Events` | Agents' events. |
| `Wardrik.Audit` | What people did. |
| `Wardrik.Deployment` | Nodes and reloading. |
| `Wardrik.Hook` | Webhook requests to triggers. |

## By ID

`Wardrik.run/3` takes and returns the protocol's JSON. Use it to build a surface of your own:

```elixir
Wardrik.run(scope, "agent.read", %{"agent" => "agt_books"})
#=> {:ok, %{"agent" => %{"id" => "agt_books"}, "status" => "idle", ...}}
```
