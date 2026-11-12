---
title: Model gateway
description: "Rate limits, circuit breakers and model failover for every model call."
sidebar:
  order: 3
---

The model gateway routes requests, enforces provider rate limits, and switches models after
failures. By default, each model has a circuit breaker that temporarily skips it after repeated
failures. Rate limits and fallback models are opt-in.

```yaml title="~/.config/wardrik/config.yaml"
models:
  gateway:
    fallbacks:
      anthropic:claude-sonnet-4-5: [openai:gpt-5, zai:glm-5.1]
    limits:
      anthropic: {requests_per_minute: 4000, tokens_per_minute: 400000}
```

- `fallbacks` is keyed by the model an agent is configured with. `limits` is keyed by provider.
- When a model’s circuit breaker is open, Wardrik skips it and tries the next configured fallback.
- A call to a provider at its limit is delayed until the provider has capacity.
- An HTTP 429 response pauses provider requests for `Retry-After`, or one second if the header is absent.
- Server errors (HTTP 5xx) and timeouts count toward the circuit breaker and trigger a fallback attempt.
- After a fallback, the rest of the turn uses the fallback.
- A call is delayed at most `wait`. Then the agent's [`retries`](/reference/agent-files/#retries)
  apply.
- Fallbacks use the deployment's API key for their provider.

## Gateway overhead

| Concurrent callers | Calls per second | Time per call |
| --- | --- | --- |
| 100 | 520,000–590,000 | 1.7–1.9 µs |
| 1,000 | 420,000–560,000 | 1.8–2.4 µs |
| 5,000 | 380,000–425,000 | 2.4–2.6 µs |

Gateway overhead per model call on a 32-thread AMD Ryzen AI Max+ 395.

- Limits are counted per node. In a [cluster](/run/cluster/), divide each provider's quota between
  the nodes.
- Each node uses only its allocated quota. If most busy agents run on one node, that node waits at its
  limit even when other nodes have unused quota. [Spread agents](/run/cluster/#spread-agents) to even it out.
- When a node is lost, the cluster runs on the remaining nodes' shares until you raise them.
- Circuit breakers are local to each node, so failures on one node do not open another node’s breaker.
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
