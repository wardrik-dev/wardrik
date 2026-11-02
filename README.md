# WardrikResearch

Deep research for agents. The `deep_research` tool splits a topic into angles, researches each in
its own subagent at once, and combines the findings into one report.

```elixir
def deps do
  [
    {:wardrik_research, "~> 0.1.0-rc.2"}
  ]
end
```

## Usage

Give an agent `WardrikResearch` next to a search tool:

```elixir
WardrikCore.start_agent(
  agent_id: "agt_analyst",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikBrave, brave: MyApp.Brave}, {WardrikResearch, max_concurrency: 3}]
)
```

With [Wardrik](https://hexdocs.pm/wardrik), offer it by name, then list `deep_research` in a
definition's `tools`:

```elixir
config :my_app, MyApp.AgentRuntime,
  capabilities: [web_search: {WardrikBrave, brave: MyApp.Brave}, deep_research: WardrikResearch]
```

Options are in `WardrikResearch`.

## What it returns

```elixir
%{
  "topic" => "AI code review tools",
  "report" => "...",
  "gaps" => [%{"angle" => "where this appears to be heading", "reason" => "it ran out of time"}]
}
```

- Researchers use the agent's model, middleware and tools, but can't start research of their own.
- Their spending counts toward the agent's budgets.
- A failed angle is listed in `"gaps"`. The call fails only when every angle does.
- Each researcher shows in the agent's events as `wardrik.subagent.started`, then `completed` or
  `failed`.

## License

Apache-2.0
