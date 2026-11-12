# Changelog

## 0.1.0-rc.2 (2026-11-02)

- Requires `wardrik_core` 0.1.0-rc.2.

## 0.1.0-rc.1 (2026-10-30)

- `deep_research`, a tool that splits a topic into angles, researches each in its own subagent at
  once, and combines the findings into one report.
- Five general angles, or your own with a prompt for each. The agent may pass its own for a single
  call.
- Researchers on the agent's model, middleware and tools. What they spend counts toward its
  budgets.
- What a researcher reads labels the answer, as if the agent had read it.
- `:max_concurrency`, `:timeout` and `:max_rounds`, to bound the researchers.
- Failed or timed-out angles listed in `"gaps"`, with the rest still combined.
- `wardrik.subagent.started`, `completed` and `failed` events for each researcher.
