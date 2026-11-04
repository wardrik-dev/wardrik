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

```elixir
children = [
  {WardrikGateway,
   name: MyApp.Gateway,
   fallbacks: %{"anthropic:claude-sonnet-4-5" => ["openai:gpt-5", "zai:glm-5.1"]},
   limits: %{"anthropic" => [requests_per_minute: 4000, tokens_per_minute: 400_000]}},
  {MyApp.AgentRuntime, middleware: [{WardrikGateway, MyApp.Gateway}]}
]
```

With [WardrikCore](https://hexdocs.pm/wardrik_core) alone, pass the same entry in an agent's
`:middleware`.

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

## Scale

| Concurrent callers | Calls per second | Time per call |
| --- | --- | --- |
| 100 | 520,000–590,000 | 1.7–1.9 µs |
| 1,000 | 420,000–560,000 | 1.8–2.4 µs |
| 5,000 | 380,000–425,000 | 2.4–2.6 µs |

Gateway overhead per model call, from `mix run bench/gateway.exs`: AMD Ryzen AI Max+ 395 (32
threads), Elixir 1.20, OTP 28, range of five runs.

## Limits

- Limits are counted per node. On several nodes, divide each provider's quota between them.
- Fallbacks use the deployment's API key for their provider. Agent definitions can't set them.

## Related

- [Running Wardrik](https://hexdocs.pm/wardrik/running-wardrik.html): `:middleware`,
  `:model_options` and the connection `:pool`.
- [`WardrikCore.Middleware`](https://hexdocs.pm/wardrik_core/WardrikCore.Middleware.html): the
  behaviour this package implements.
- [Model gateway](https://docs.wardrik.dev/run/model-gateway/): the same settings in the daemon's
  `config.yaml`.

## License

Apache-2.0
