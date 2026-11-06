# WardrikBrave

Web search for agents, through Brave's LLM Context API. A search returns the relevant passages of
each page, not just links.

```elixir
def deps do
  [
    {:wardrik_brave, "~> 0.1.0-rc.2"}
  ]
end
```

## Usage

Set `BRAVE_API_KEY` and `ANTHROPIC_API_KEY` before starting a fresh IEx session.

```elixir
Mix.install([{:wardrik_brave, "~> 0.1.0-rc.2"}])

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, _brave} =
  WardrikBrave.start_link(name: MyApp.Brave, api_key: System.fetch_env!("BRAVE_API_KEY"))

WardrikCore.start_agent(
  agent_id: "agt_triage",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikBrave, brave: MyApp.Brave}]
)
```

## With Wardrik

In an existing app, register the capability in `config/runtime.exs`:

```elixir
config :my_app, MyApp.AgentRuntime, capabilities: [web_search: {WardrikBrave, brave: MyApp.Brave}]
```

Enable `web_search` in the agent's definition. Use the scope returned by your runtime's `as/2`:

```elixir
scope = MyApp.AgentRuntime.as("maria")

Wardrik.Agent.define(scope, "agt_triage",
  model: "anthropic:claude-haiku-4-5",
  tools: ["web_search"]
)
```

See [Run Wardrik](https://hexdocs.pm/wardrik/running-wardrik.html) for runtime setup.

## Keys

- Each search uses `BRAVE_API_KEY` from the agent's `WardrikCore.Keys` first, then `:api_key`.
- If the agent's key source always returns it, omit the process: `{WardrikBrave, []}`.
- Keys are never saved with the agent's state.
- With no key, the search returns an error saying so.

## License

Apache-2.0
