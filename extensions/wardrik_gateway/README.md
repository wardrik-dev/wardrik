# WardrikGateway

Rate limits, circuit breakers and model failover for [Wardrik](https://hexdocs.pm/wardrik) agents'
model calls.

```elixir
def deps do
  [
    {:wardrik_gateway, "~> 0.1.0-rc.1"}
  ]
end
```

## Usage

Set the API keys for each configured model provider before starting IEx. In a fresh session:

```elixir
Mix.install([{:wardrik_gateway, "~> 0.1.0-rc.1"}, {:wardrik_core, "~> 0.1.0-rc.4"}])

children = [
  {WardrikGateway,
   name: MyApp.Gateway,
   fallbacks: %{"anthropic:claude-sonnet-4-5" => ["openai:gpt-5", "zai:glm-5.1"]},
   limits: %{"anthropic" => [requests_per_minute: 4000, tokens_per_minute: 400_000]}},
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "agt_triage",
    model: "anthropic:claude-sonnet-4-5",
    middleware: [{WardrikGateway, MyApp.Gateway}]
  )
```

In an existing Wardrik app, start the gateway before `MyApp.AgentRuntime`.
Pass `middleware: [{WardrikGateway, MyApp.Gateway}]` to the runtime.
See [Run Wardrik](https://hexdocs.pm/wardrik/running-wardrik.html) for runtime setup.

- A model with an open breaker is skipped. The call goes to the next model in `fallbacks`.
- A call to a provider at its limit is delayed until the provider has capacity.
- A 429 delays calls to that provider for its `Retry-After`, or one second.
- A 5xx, a 529 or a timeout counts towards the model's breaker. The call goes to the next model.
- After a fallback, the rest of the turn uses the fallback.
- A call is delayed at most `:wait`, 10 minutes by default. Then
  [`WardrikCore.Retry`](https://hexdocs.pm/wardrik_core/WardrikCore.Retry.html) applies.

`configure/2` replaces the settings at runtime:

```elixir
WardrikGateway.configure(MyApp.Gateway, limits: %{"anthropic" => [requests_per_minute: 2000]})
```

See [benchmark results](https://github.com/wardrik-dev/wardrik/blob/main/extensions/wardrik_gateway/bench/README.md) for gateway overhead measurements.

## Limits

- Limits are counted per node. On several nodes, divide each provider's quota between them.
- Fallbacks use the deployment's API key for their provider. Agent definitions can't set them.

## Related

- [Running Wardrik](https://hexdocs.pm/wardrik/running-wardrik.html): `:middleware`,
  `:model_options` and the connection `:pool`.
- [`Wardrik.Middleware`](https://hexdocs.pm/wardrik_core/Wardrik.Middleware.html): the
  behaviour this package implements.
- [Model gateway](https://docs.wardrik.dev/run/model-gateway/): the same settings in the daemon's
  `config.yaml`.

## License

Apache-2.0
