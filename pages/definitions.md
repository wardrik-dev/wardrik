# Define agents

A definition says what an agent is and what it may do: its model, instructions, tools and policy.
Define an agent and Wardrik starts it, keeps the definition, and starts it from the definition
again each time it wakes.

A definition is the same whether it comes from an agent file's frontmatter, HTTP, a CLI or your
code.

> See it in action: [Give agents tools](../notebooks/tools-demo.livemd)

## Offer what agents may use

Definitions name tools and policies; Wardrik's options say what those names are. In a fresh IEx
session, paste a tool module, then start Wardrik with it:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.2"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer

  @impl true
  def authorize(_request, _opts), do: :ok
end

defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver

  # Every agent here works for Maria.
  @impl true
  def resolve(_request, _opts),
    do: {:ok, %Wardrik.Resolved{principal: Wardrik.principal("acme/@maria")}}
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

scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria")
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

Wardrik.Agent.define(scope, "agt_assistant", definition)
#=> {:ok,
#=>  %Wardrik.Agent{
#=>    id: "agt_assistant",
#=>    status: :idle,
#=>    node: "nonode@nohost",
#=>    pending: 0,
#=>    interrupts: [],
#=>    ...
#=>  }}
```

Your app picks the agent's ID, as `agt_01JF8X5RQ2` or `agt_assistant`. Any text of 1 to 255
characters works, without control characters. Wardrik never reads anything from it.

`Wardrik.Agent.define/3` takes a keyword list too. A definition is stored as the protocol's JSON,
so YAML frontmatter, JSON and `Wardrik.Definition.new!/1` all give the same one.

Define it again to change it. A running agent takes the new definition from its next turn:

```elixir
Wardrik.Agent.define(scope, "agt_assistant",
  model: "anthropic:claude-haiku-4-5",
  tools: ["orders"],
  policy: "careful"
)
```

The agent acts as whoever your resolver says, with their credentials.

### Keys

| Key | Means |
| --- | --- |
| `model` | Required. The model, as `provider:model`. |
| `instructions` | The system prompt, sent with every model call. |
| `tools` | What it may call. See below. |
| `context` | Files read into every turn, as `[MEMORY.md]` or `{files: [...], max_bytes: 65536}`. See `Wardrik.Workspaces`. |
| `workspace` | Other agents' workspaces it mounts, each under `shared/<name>/`, as `{shared: {runbooks: agt_runbooks}}`. Only those its resolver shares. |
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
  * `"agents/*"` to work with the agents your authorizer lets it reach, by their IDs, and
    `"self/*"` to work with itself. See
    `Wardrik.AgentTools`.
  * `"*"` for everything except `agents/*` and `self/*`.

Only an agent declared in a file writes `allow_after` in its policy in place. Any other names a
policy that has it.

Nothing in a definition is ignored. A name Wardrik doesn't offer returns `invalid_request`. A key
it doesn't support yet returns `not_supported`, naming the key.

## Read it back

```elixir
Wardrik.Agent.definition(scope, "agt_assistant")
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
Wardrik.Agent.stop(scope, "agt_assistant")
Wardrik.Agent.read(scope, "agt_assistant")
#=> {:ok, %Wardrik.Agent{id: "agt_assistant", status: :asleep, ...}}
```

| Function | Does |
| --- | --- |
| `Wardrik.Agent.stop/3` | Puts it to sleep now. |
| `Wardrik.Agent.spawn/3` | Wakes it without asking anything. |
| `Wardrik.Agent.clear/3` | Empties its conversation. Returns `conflict` while it runs or waits on a person. |
| `Wardrik.Agent.forget/3` | Stops it, and deletes its conversations and definition. |
| `Wardrik.Agent.calls/3` | Lists the tool calls it's running, with how long each has run. |
| `Wardrik.Agent.kill/2` | Stops one call. The model gets an error for it, and the turn goes on. |
| `Wardrik.Agents.cancel/2` | Stops what each agent it names, or every agent the scope may see, is doing. |
| `Wardrik.Agents.forget/2` | Forgets each agent it names, or every agent the scope may see. |

Each change is recorded in the audit, with who made it.

## Conversations

One agent can hold many conversations at once, as a chat app holds one per thread. Name the
conversation with `:conversation`. Asking one calls the model, so set `ANTHROPIC_API_KEY` first:

```elixir
Wardrik.Agent.ask(scope, "agt_assistant", "Where's order A-1?", conversation: "C1")
#=> {:ok, %Wardrik.Message{id: "msg_Xq3f...", cursor: "..."}}

Wardrik.Agent.reply(scope, "agt_assistant", "And order A-2?", conversation: "C1")
```

A conversation:

  * runs on the agent's definition, with its own history, log and queue.
  * starts when something asks it, sleeps as the agent does, and goes when the agent is forgotten.
  * has no definition or triggers of its own.

Your app picks the conversation's ID, as it picks the agent's. Your authorizer decides a
conversation as its agent, `{:agent, "agt_assistant"}`.

Over HTTP, a conversation's routes sit under `/v1/agents/{agent}/conversations/{conversation}`.
