# Changelog

## 0.1.0-rc.4 (unreleased)

- `WardrikGateway`: middleware for agents' model calls, with limits per provider, a breaker per
  model, and fallbacks by model.
- A call waits up to `:wait` for room or for a model to come back, then the agent's retries take
  over.
- `configure/2` changes the settings while it runs.
- `[:wardrik_gateway, :failover | :limited | :breaker_opened | :breaker_closed]` telemetry.
