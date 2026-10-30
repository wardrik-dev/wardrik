# Define agents

A definition says what an agent is and what it may do: its model, instructions, tools and policy.
Define an agent and Wardrik starts it, keeps the definition, and starts it from the definition
again each time it wakes.

A definition is the same whether it comes from an agent file's frontmatter, HTTP, a CLI or your
code.

## Offer what agents may use

Definitions name tools and policies; Wardrik's options say what those names are. In a fresh IEx
session, paste a tool module, then start Wardrik with it:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.1"}])

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
    capabilities: [orders: {MyApp.Orders, %{"A-1" => "shipped"}}],
    policies: [careful: [ask: ["order_*"], deny: ["shell/*"]]]
  )

scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria", roles: [:owner], resources: ["acme/@maria/*"])
```

  * `:capabilities` - tools a definition names, each a `WardrikCore.Capability`.
  * `:policies` - policies a definition names, each as its rules.
  * `:mcp` - MCP servers a definition names, as `github/*`. See [MCP servers](servers.md).
  * `:middleware` - wraps every agent's calls.
  * `:idle_timeout` - seconds a defined agent idles before it sleeps, or `:infinity`. `900` unless
    set.

In your app, set them in config instead:
`config :my_app, MyApp.AgentRuntime, capabilities: [...], policies: [...]`.

## Define one

```elixir
definition =
  Wardrik.Definition.new!(
    model: "anthropic:claude-haiku-4-5",
    instructions: "You answer questions about Maria's orders.",
    tools: ["orders", "files"],
    policy: [ask: ["order_status"], budget: [tokens: 400_000, per: :day]],
    timeout: 600
  )

Wardrik.Agent.define(scope, "acme/@maria/assistant", definition)
#=> {:ok,
#=>  %Wardrik.Agent{
#=>    id: "acme/@maria/assistant",
#=>    name: "assistant",
#=>    status: :idle,
#=>    node: "nonode@nohost",
#=>    pending: 0,
#=>    interrupts: [],
#=>    ...
#=>  }}
```

`Wardrik.Agent.define/3` takes a keyword list too. A definition is stored as the protocol's JSON,
so YAML frontmatter, JSON and `Wardrik.Definition.new!/1` all give the same one.

Define it again to change it. A running agent takes the new definition from its next turn:

```elixir
Wardrik.Agent.define(scope, "acme/@maria/assistant",
  model: "anthropic:claude-haiku-4-5",
  tools: ["orders"],
  policy: "careful"
)
```

A user's agent, as `acme/@maria/assistant`, acts as `acme/@maria`, with her credentials. An org's
agent, as `acme/digest`, acts as the org.

### Keys

| Key | Means |
| --- | --- |
| `model` | Required. The model, as `provider:model`. |
| `instructions` | The system prompt, sent with every model call. |
| `tools` | What it may call. See below. |
| `context` | Files read into every turn, as `[MEMORY.md]` or `{files: [...], max_bytes: 65536}`. See `Wardrik.Workspaces`. |
| `workspace` | File trees shared with it, each under `shared/<name>/`, as `{shared: {team: acme}}`. |
| `policy` | A policy by name, or its rules in place, budget and judge included. See [Policies](policies.md). |
| `timeout` | Seconds a turn may take. |
| `max_iterations` | Rounds of tool calls a turn may make, or `infinity`. `25` unless set. |
| `idle_timeout` | Seconds it idles before it sleeps, or `infinity`. |
| `retries` | How a failed model call is retried: `attempts` (`6`), `max_wait` in seconds (`60`), and `on_exhausted`, `ask` or `fail`. See `WardrikCore.Retry`. |
| `compaction` | When older history is summarised, as shares of the model's window. `{at: 0.6, keep: 0.25}` unless set. Give `window` where the catalog has none, or `false` to never compact. See `Wardrik.Compaction`. |
| `triggers` | What asks it something on a clock, from a feed or from a webhook. See [Trigger agents](triggers.md). |
| `channels` | Chat apps it may answer in, by their names in Wardrik's `:channels`. |
| `notify` | Where its notices go. See `Wardrik.Notify`. |
| `display_name`, `description` | What a person calls it, and what it's for. |

`tools` takes:

  * a capability by name, as `"orders"` above, or `"files"` for a file tree of its own.
  * `"server/*"` for every tool of an MCP server.
  * `"workers/*"` for the tools workers offer it.
  * `"agents/*"` to work with its org's agents, and `"self/*"` to work with itself. See
    `Wardrik.AgentTools`.
  * `"*"` for everything except `agents/*` and `self/*`.

Only an agent declared in a file writes `allow_after` in its policy in place. Any other names a
policy that has it.

Nothing in a definition is ignored. A name Wardrik doesn't offer returns `invalid_request`. A key
it doesn't support yet returns `not_supported`, naming the key.

## Read it back

```elixir
Wardrik.Agent.definition(scope, "acme/@maria/assistant")
#=> {:ok,
#=>  %Wardrik.Definition{
#=>    model: "anthropic:claude-haiku-4-5",
#=>    tools: ["orders"],
#=>    policy: "careful",
#=>    ...
#=>  }, []}
```

The third element lists the tools it names that offer nothing yet, like an MCP server that's down.

## Sleep and wake

A defined agent sleeps after `idle_timeout` with nothing to do. It wakes, with its conversation,
when something asks it. Asking, deciding and signing in wake it. Reading it doesn't; it returns
`asleep`:

```elixir
Wardrik.Agent.stop(scope, "acme/@maria/assistant")
Wardrik.Agent.read(scope, "acme/@maria/assistant")
#=> {:ok, %Wardrik.Agent{id: "acme/@maria/assistant", status: :asleep, ...}}
```

| Function | Does |
| --- | --- |
| `Wardrik.Agent.stop/3` | Puts it to sleep now. |
| `Wardrik.Agent.spawn/3` | Wakes it without asking anything. |
| `Wardrik.Agent.clear/3` | Empties its conversation. Returns `conflict` while it runs or waits on a person. |
| `Wardrik.Agent.forget/3` | Stops it, and deletes its conversations and definition. |
| `Wardrik.Agent.calls/3` | Lists the tool calls it's running, with how long each has run. |
| `Wardrik.Agent.kill/4` | Stops one call. The model gets an error for it, and the turn goes on. |
| `Wardrik.Agents.cancel/2` | Stops what every agent the patterns cover is doing. |
| `Wardrik.Agents.forget/2` | Forgets every agent the patterns cover. |

Each change is recorded in the audit, with who made it.

## Conversations

One agent can hold many conversations at once, as a chat app holds one per thread. A
conversation's ID is the agent's ID plus one segment. Asking one calls the model, so set
`ANTHROPIC_API_KEY` first:

```elixir
Wardrik.Agent.ask(scope, "acme/@maria/assistant/C1-1696.1234", "Where's order A-1?")
#=> {:ok, %Wardrik.Message{id: "msg_Xq3f...", cursor: "..."}}
```

A conversation:

  * runs on the agent's definition, with its own history, log and queue.
  * starts when something asks it, sleeps as the agent does, and goes when the agent is forgotten.
  * has no definition or triggers of its own. Defining one returns `invalid_request`.

Its resource is the agent's plus the conversation, as
`acme/@maria/agent/assistant/conversation/C1-1696.1234`. A statement on
`acme/@maria/agent/assistant` doesn't reach it; `acme/@maria/agent/assistant/*` does.

No HTTP route reaches a conversation. Read its events through the agent's org.
