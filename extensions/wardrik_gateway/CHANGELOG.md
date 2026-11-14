# Changelog

## 0.1.0-rc.2 (2026-11-14)

- Requires `wardrik_core` 0.1.0-rc.8, whose modules tools and middleware are written with are
  named under `Wardrik`.

## 0.1.0-rc.1

- `WardrikGateway`: middleware for agents' model calls, with limits per provider, a breaker per
  model, and fallbacks by model.
- A call waits up to `:wait` for room or for a model to come back, then the agent's retries take
  over.
- `configure/2` changes the settings while it runs.
- `[:wardrik_gateway, :failover | :limited | :breaker_opened | :breaker_closed]` telemetry.
