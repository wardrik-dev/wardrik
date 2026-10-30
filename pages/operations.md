# Operations

Everything people and programs do with agents is an operation. Each is defined once, and works the
same from your code, HTTP, Slack or a terminal.

## As functions

Each operation is a function named by its ID. `agent.ask` is `Wardrik.Agent.ask/3`:

```elixir
Wardrik.Agent.ask(scope, "acme/books", "Which bills are due this week?")
#=> {:ok, %Wardrik.Message{id: "msg_Xq3f...", cursor: "eyJhY21lL2Jvb2tzIjo0MX0"}}

Wardrik.Agent.read(scope, "acme/books")
#=> {:ok,
#=>  %Wardrik.Agent{
#=>    id: "acme/books",
#=>    name: "books",
#=>    status: :running,
#=>    node: "wardrik@box1",
#=>    pending: 0,
#=>    activity: %Wardrik.Activity{doing: [%{"type" => "wardrik.message.started", ...}], ...},
#=>    interrupts: [],
#=>    cursor: "eyJhY21lL2Jvb2tzIjo0M30"
#=>  }}

Wardrik.Agent.cancel(scope, "acme/books")
#=> :ok
```

Each function takes, in order:

1. the scope.
2. the operation's path parameters, each as text or as the struct it names, like
   `%Wardrik.Agent{}` for an agent or `%Wardrik.Interrupt{}` for a call it waits on.
3. the rest of its input, as a keyword list.

Each returns a struct, a list of them, or `:ok`. It returns `{:error, %Wardrik.Error{}}`, with the
error's `type` and `message`, when it fails. Operations that can be streamed also have a `stream_`
function; see [Events and the audit](events.md).

| Returns | Operations |
| --- | --- |
| `%Wardrik.Agent{}` | define, read, clear, spawn, stop, move; a list from `Wardrik.Agents.list/2` |
| `%Wardrik.Message{}` | ask |
| `[%Wardrik.Decision{}]` | decide, approve, deny |
| `[%Wardrik.Interrupt{}]` | `Wardrik.Interrupts.list/2` |
| `%Wardrik.Page{}` of `%Wardrik.Event{}` | events, `Wardrik.Events.list/2`, `Wardrik.Audit.list/2` |
| `%Wardrik.Timeline{}`, `%Wardrik.Runs{}` | timeline, runs |
| `[%Wardrik.Call{}]`, `%Wardrik.Authorization{}` | calls, authorization |
| `:ok` | cancel, forget, kill |

An event's `data`, an activity's `doing` and a timeline's items stay as the protocol's maps, since
their shape depends on their type.

| Module | Operations |
| --- | --- |
| `Wardrik.Agent` | One agent: define, ask, read, cancel, decide, approve, deny, stop, spawn, clear, forget, move, its triggers, calls, events, timeline and runs. |
| `Wardrik.Agents` | The agents a scope can see: list, cancel and forget them. |
| `Wardrik.Interrupts` | What agents wait on. |
| `Wardrik.Events` | Agents' events. |
| `Wardrik.Audit` | What people did. |
| `Wardrik.Tokens` | API tokens. |
| `Wardrik.Connections` | Accounts people and orgs connect. |
| `Wardrik.MCPServers` | MCP servers orgs and people add. |
| `Wardrik.Ceilings` | What orgs have spent. |
| `Wardrik.Deployment` | Nodes and reloading. |
| `Wardrik.Hook` | Webhook requests to triggers. |

## By ID

`Wardrik.run/3` runs an operation by its ID. It takes and returns the protocol's JSON, which is how
a surface you build reaches operations:

```elixir
Wardrik.run(scope, "agent.ask", %{"agent" => "acme/books", "content" => "What's due?"})
#=> {:ok, %{"message" => %{"id" => "msg_Xq3f...", "cursor" => "eyJhY21lL2Jvb2tzIjo0MX0"}}}
```
