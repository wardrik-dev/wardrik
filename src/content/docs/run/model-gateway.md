---
title: Model gateway
description: "Rate limits, circuit breakers and model failover for every model call."
sidebar:
  order: 3
---

Every model call goes through the daemon's gateway. By default it has one circuit breaker per
model and no limits or fallbacks.

```yaml title="~/.config/wardrik/config.yaml"
models:
  gateway:
    fallbacks:
      anthropic:claude-sonnet-4-5: [openai:gpt-5, zai:glm-5.1]
    limits:
      anthropic: {requests_per_minute: 4000, tokens_per_minute: 400000}
```

- `fallbacks` is keyed by the model an agent is configured with. `limits` is keyed by provider.
- A model with an open breaker is skipped. The call goes to the next model in `fallbacks`.
- A call to a provider at its limit is delayed until the provider has capacity.
- A 429 delays calls to that provider for its `Retry-After`, or one second.
- A 5xx, a 529 or a timeout counts towards the model's breaker. The call goes to the next model.
- After a fallback, the rest of the turn uses the fallback.
- A call is delayed at most `wait`. Then the agent's [`retries`](/reference/agent-files/#retries)
  apply.
- Fallbacks use the deployment's API key for their provider.

## Scale

| Concurrent callers | Calls per second | Time per call |
| --- | --- | --- |
| 100 | 520,000–590,000 | 1.7–1.9 µs |
| 1,000 | 420,000–560,000 | 1.8–2.4 µs |
| 5,000 | 380,000–425,000 | 2.4–2.6 µs |

Gateway overhead per model call on a 32-thread AMD Ryzen AI Max+ 395.

- Limits are counted per node. In a [cluster](/run/cluster/), divide each provider's quota between
  the nodes.
- The daemon opens up to 64 connections per provider host.

## Settings

| Key | Default | Description |
| --- | --- | --- |
| `fallbacks` | `{}` | models to call, in order, by the model configured |
| `limits` | `{}` | `requests_per_minute` and `tokens_per_minute`, by provider |
| `breaker.failures` | `5` | failures that open a model's breaker |
| `breaker.within` | `30` | seconds the failures are counted over |
| `breaker.open_for` | `30` | seconds before one call is let through to test the model |
| `wait` | `600` | maximum seconds a call is delayed |

`wardrik reload` applies changes.
