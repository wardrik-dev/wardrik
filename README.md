# WardrikGateway

Rate limits, circuit breakers and model failover for agents' model calls. When thousands of
agents share a provider, it keeps them under its limits, routes around an outage, and holds calls
until a model comes back.

```elixir
def deps do
  [
    {:wardrik_gateway, "~> 0.1.0-rc.4"}
  ]
end
```

## Usage

Let's start a gateway beside Wardrik and give every agent its middleware:

```elixir
children = [
  {WardrikGateway,
   name: MyApp.Gateway,
   fallbacks: %{"anthropic:claude-sonnet-4-5" => ["openai:gpt-5", "zai:glm-5.1"]},
   limits: %{"anthropic" => [requests_per_minute: 4000, tokens_per_minute: 400_000]}},
  {MyApp.AgentRuntime, middleware: [{WardrikGateway, MyApp.Gateway}]}
]
```

Notice the gateway is a process of its own, and the middleware names it. With `WardrikCore`
alone, give the same entry as an agent's `:middleware`.

- A model whose breaker is open is skipped for the next in its `fallbacks`.
- A provider at its limit holds the call until there's room. A 429 holds it for as long as its
  `Retry-After` says.
- A 5xx, a 529 or a timeout counts towards the model's breaker, and the call moves on.
- A turn that moved to a fallback stays on it until the turn ends.
- A call waits up to `:wait`, ten minutes unless set, for room or for a model to come back. Then
  the agent's own retries take over.

Change it while it runs:

```elixir
WardrikGateway.configure(MyApp.Gateway, limits: %{"anthropic" => [requests_per_minute: 2000]})
```

## Limits

- Limits count on each node. With several nodes, divide a provider's quota between them.
- Fallbacks are called with the deployment's keys for their provider, so they're the operator's
  to set, never an agent definition's.

## License

Apache-2.0
