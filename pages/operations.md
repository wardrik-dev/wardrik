# Operations

Everything people and programs do with agents is an operation, defined once, and the same from your
code, HTTP, Slack or a terminal.

## As functions

Each operation is a function, named by its ID. `agent.ask` is `Wardrik.Agent.ask/3`:

```elixir
{:ok, %Wardrik.Message{id: id, cursor: cursor}} =
  Wardrik.Agent.ask(scope, "acme/books", "Which bills are due this week?")

{:ok, %Wardrik.Agent{status: :idle}} = Wardrik.Agent.read(scope, "acme/books")
{:ok, %Wardrik.Timeline{items: items}} = Wardrik.Agent.timeline(scope, "acme/books")
:ok = Wardrik.Agent.cancel(scope, "acme/books")
```

Each takes the scope, then the operation's path parameters, then the rest of its input as a keyword
list. Each answers a struct, a list of them, or `:ok`, and `{:error, %Wardrik.Error{}}` with the
error's `type` and `message` when it can't. Operations that can be streamed have a `stream_`
function too; see [Events and the audit](events.md).

| Answers | Operations |
| --- | --- |
| `%Wardrik.Agent{}` | define, read, clear, spawn, stop; a list of them from `Wardrik.Agents.list/2` |
| `%Wardrik.Message{}` | ask |
| `[%Wardrik.Decision{}]` | decide, approve, deny |
| `[%Wardrik.Interrupt{}]` | `Wardrik.Interrupts.list/2` |
| `%Wardrik.Page{}` of `%Wardrik.Event{}` | events, `Wardrik.Events.list/2`, `Wardrik.Audit.list/2` |
| `%Wardrik.Timeline{}`, `%Wardrik.Runs{}` | timeline, runs |
| `[%Wardrik.Call{}]`, `%Wardrik.Authorization{}` | calls, authorization |
| `:ok` | cancel, forget, kill |

An event's `data`, an activity's `doing`, and a timeline's items are each the protocol's map, since
each takes a different shape by its type.

| Module | Operations |
| --- | --- |
| `Wardrik.Agent` | one agent: define, ask, read, cancel, decide, approve, deny, stop, spawn, clear, forget, its calls, events, timeline and runs |
| `Wardrik.Agents` | the agents a scope can see: list, cancel and forget them |
| `Wardrik.Interrupts` | what they wait on |
| `Wardrik.Events` | their events |
| `Wardrik.Audit` | what people did |

## By ID

The same run by ID, taking and answering the protocol's JSON, which is how a surface you build
reaches them:

```elixir
Wardrik.run(scope, "agent.ask", %{"agent" => "acme/books", "content" => "What's due?"})
```
