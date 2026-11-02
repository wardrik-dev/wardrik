# Tools

Run the [setup](running-agents.md#setup) in IEx first.

## Capabilities

A capability is a module that returns an agent's tools:

```elixir
defmodule MyApp.Orders do
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, orders) do
    [
      WardrikCore.Tool.new!(
        name: "order_status",
        description: "Say where an order is.",
        schema: [order_id: [type: :string, required: true]],
        run: fn %{order_id: id}, _context -> {:ok, Map.get(orders, id, "unknown")} end
      )
    ]
  end
end

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    capabilities: [{MyApp.Orders, %{"1001" => "shipped"}}]
  )

:ok = WardrikCore.ask(agent, "Where is order 1001?")
```

- The second element, here the orders, is passed to `tools/2` as options.
- Each call runs in its own process. A crash or timeout becomes an error the model sees.

## Annotations

```elixir
tool =
  WardrikCore.Tool.new!(
    name: "order_status",
    description: "Say where an order is.",
    schema: [order_id: [type: :string, required: true]],
    run: fn %{order_id: _id}, _context -> {:ok, "shipped"} end,
    annotations: [read_only: true, idempotent: true]
  )

WardrikCore.Tool.annotation(tool, :idempotent)
#=> true
```

- A `read_only` or `idempotent` call is retried on failure, and repeated after a crash.
- Other packages read them too, such as a policy that allows every `read_only` tool.
- See `WardrikCore.Tool` for the full list.

## Reporting cost

Return the context with a measurement added:

```elixir
WardrikCore.Tool.new!(
  name: "enrich",
  description: "Find a person's company from their email.",
  schema: [email: [type: :string, required: true]],
  run: fn %{email: email}, context ->
    {:ok, %{email: email, company: "Acme"}, WardrikCore.Context.measure(context, :usd, 0.01)}
  end
)
```

The cost adds up on the tool call and the turn. See [Tracing](tracing.md).
