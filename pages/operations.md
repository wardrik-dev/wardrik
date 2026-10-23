# Operations

Everything people and programs do with agents is an operation, defined once, and the same from your
code, HTTP, Slack or a terminal.

## As functions

Each operation is a function, named by its ID. `agent.ask` is `Wardrik.Agent.ask/3`:

```elixir
{:ok, %{"message" => %{"id" => id, "cursor" => cursor}}} =
  Wardrik.Agent.ask(scope, "acme/books", %{"content" => "Which bills are due this week?"})

{:ok, %{"status" => "idle"}} = Wardrik.Agent.read(scope, "acme/books")
{:ok, %{"items" => items}} = Wardrik.Agent.timeline(scope, "acme/books")
{:ok, nil} = Wardrik.Agent.cancel(scope, "acme/books")
```

Each takes the scope, then the operation's path parameters, then the rest of its input, with string
keys. Each answers `{:ok, output}`, or `{:error, %Wardrik.Error{}}` with the error's `type` and
`message`. Operations that can be streamed have a `stream_` function too; see
[Events and the audit](events.md).

| Module | Operations |
| --- | --- |
| `Wardrik.Agent` | one agent: define, ask, read, cancel, decide, approve, deny, stop, spawn, clear, forget, its calls, events, timeline and runs |
| `Wardrik.Agents` | the agents a scope can see: list, cancel and forget them |
| `Wardrik.Interrupts` | what they wait on |
| `Wardrik.Events` | their events |
| `Wardrik.Audit` | what people did |

## By ID

The same run by ID, which is how a surface you build reaches them:

```elixir
Wardrik.run(scope, "agent.ask", %{"agent" => "acme/books", "content" => "What's due?"})
```
