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

Set `BRAVE_API_KEY` and `ANTHROPIC_API_KEY` before starting a fresh IEx session.

Give an agent `WardrikResearch` next to a search tool:

```elixir
Mix.install([{:wardrik_research, "~> 0.1.0-rc.2"}, {:wardrik_brave, "~> 0.1.0-rc.2"}])

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, _brave} =
  WardrikBrave.start_link(name: MyApp.Brave, api_key: System.fetch_env!("BRAVE_API_KEY"))

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "agt_analyst",
    model: "anthropic:claude-haiku-4-5",
    capabilities: [{WardrikBrave, brave: MyApp.Brave}, {WardrikResearch, max_concurrency: 3}]
  )
```

## With Wardrik

In an existing app, register the capability in `config/runtime.exs`:

```elixir
config :my_app, MyApp.AgentRuntime,
  capabilities: [web_search: {WardrikBrave, brave: MyApp.Brave}, deep_research: WardrikResearch]
```

Enable `deep_research` in the agent's definition. Use the scope returned by your runtime's `as/2`:

```elixir
scope = MyApp.AgentRuntime.as("maria")

Wardrik.Agent.define(scope, "agt_triage",
  model: "anthropic:claude-haiku-4-5",
  tools: ["deep_research"]
)
```

See [Run Wardrik](https://hexdocs.pm/wardrik/running-wardrik.html) for runtime setup.

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
