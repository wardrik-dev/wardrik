# Define agents

> See it in action: [Give agents tools](../notebooks/tools-demo.livemd)

A definition says what an agent is: model, instructions, tools and policy. Wardrik keeps it, and
starts the agent from it each time it wakes.

## Setup

Wardrik's options say what the names in a definition mean.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.7"}])

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

defmodule MyApp.Orders do
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, orders) do
    [
      WardrikCore.Tool.new!(
        name: "order_status",
        description: "Says where an order is.",
        schema: [order_id: [type: :string, required: true]],
        run: fn %{order_id: id}, _context -> {:ok, Map.get(orders, id, "unknown")} end
      )
    ]
  end
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []},
    capabilities: [orders: {MyApp.Orders, %{"A-1" => "shipped"}}],
    policies: [careful: [ask: ["order_*"], deny: ["shell/*"]]]
  )

scope = Wardrik.as(MyApp.AgentRuntime, "maria")
```

- `:capabilities` - tools by name, each a `WardrikCore.Capability`.
- `:policies` - policies by name.
- `:mcp` - MCP servers. See [MCP servers](servers.md).
- `:idle_timeout` - seconds an agent idles before it sleeps. `900` unless set.

## Define one

```elixir
Wardrik.Agent.define(scope, "agt_assistant",
  model: "anthropic:claude-haiku-4-5",
  instructions: "You answer questions about Maria's orders.",
  tools: ["orders", "files"],
  policy: [ask: ["order_status"], budget: [tokens: 400_000, per: :day]],
  timeout: 600
)
#=> {:ok, %Wardrik.Agent{id: "agt_assistant", status: :idle, ...}}

# Define it again to change it. A running agent takes it from its next turn.
Wardrik.Agent.define(scope, "agt_assistant",
  model: "anthropic:claude-haiku-4-5",
  tools: ["orders"],
  policy: "careful"
)

Wardrik.Agent.definition(scope, "agt_assistant")
#=> {:ok, %Wardrik.Definition{model: "anthropic:claude-haiku-4-5", policy: "careful", ...}, []}
```

- Your app picks the ID: 1 to 255 characters, no control characters. Wardrik never parses it.
- A definition can also be a `Wardrik.Definition.new!/1`, JSON, or an agent file's YAML.
- `definition/2`'s last element lists tools it names that offer nothing yet.
- A name Wardrik doesn't offer returns `invalid_request`. An unsupported key returns `not_supported`.

## Keys

| Key | Means |
| --- | --- |
| `model` | Required, as `provider:model`. |
| `instructions` | The system prompt. |
| `tools` | What it may call. See below. |
| `policy` | A policy by name, or its rules. See [Policies](policies.md). |
| `context` | Files read into every turn. See `Wardrik.Workspaces`. |
| `workspace` | Other agents' workspaces it mounts. See `Wardrik.Workspaces`. |
| `timeout` | Seconds a turn may take. |
| `max_iterations` | Rounds of tool calls per turn, or `infinity`. `25` unless set. |
| `idle_timeout` | Seconds before it sleeps, or `infinity`. |
| `retries` | How failed model calls retry. See `WardrikCore.Retry`. |
| `model_options` | `temperature`, `top_p`, `max_tokens`, `reasoning_effort`, and the call's `receive_timeout`, `stream_idle_timeout` and `total_timeout` in seconds. Nothing else. |
| `compaction` | When old history is summarised. See `Wardrik.Compaction`. |
| `triggers` | See [Trigger agents](triggers.md). |
| `channels` | Chat apps it answers in, by name in Wardrik's `:channels`. |
| `notify` | Where its notices go. See `Wardrik.Notify`. |
| `display_name`, `description` | For people, and for `agents_list`. |

`tools` takes:

- a capability by name, as `"orders"`, or `"files"` for a file tree of its own.
- `"github/*"` for every tool of an MCP server.
- `"workers/*"` for tools workers offer. See `Wardrik.Workers`.
- `"agents/*"` and `"self/*"` to work with agents. See `Wardrik.AgentTools`.
- `"*"` for everything but `agents/*` and `self/*`.

## Sleep and wake

An agent sleeps after `idle_timeout`. Asking, deciding or signing in wakes it. Reading doesn't.

```elixir
Wardrik.Agent.stop(scope, "agt_assistant")
Wardrik.Agent.read(scope, "agt_assistant")
#=> {:ok, %Wardrik.Agent{id: "agt_assistant", status: :asleep, ...}}
```

| Function | Does |
| --- | --- |
| `Wardrik.Agent.stop/3` | Puts it to sleep. |
| `Wardrik.Agent.spawn/2` | Wakes it. |
| `Wardrik.Agent.clear/3` | Empties its conversation. `conflict` while it runs. |
| `Wardrik.Agent.forget/2` | Deletes it, its conversations and its definition. |
| `Wardrik.Agent.calls/3` | Lists the tool calls it's running. |
| `Wardrik.Agent.kill/2` | Stops one call. The model gets an error. |
| `Wardrik.Agents.cancel/2` | Stops what many agents are doing. |
| `Wardrik.Agents.forget/2` | Forgets many agents. |

Each change goes in the [audit](events.md#the-audit).

## Conversations

One agent can hold many conversations, as a chat app has threads:

```elixir
Wardrik.Agent.ask(scope, "agt_assistant", "Where's order A-1?", conversation: "C1")
Wardrik.Agent.reply(scope, "agt_assistant", "And order A-2?", conversation: "C1")
```

- Each has its own history, log and queue, and runs on the agent's definition.
- Your app picks its ID. Your authorizer sees it as its agent, `{:agent, "agt_assistant"}`.
- Over HTTP: `/v1/agents/{agent}/conversations/{conversation}`.
