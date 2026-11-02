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

```elixir
children = [{WardrikBrave, name: MyApp.Brave, api_key: System.fetch_env!("BRAVE_API_KEY")}]

WardrikCore.start_agent(
  agent_id: "agt_triage",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikBrave, brave: MyApp.Brave}]
)
```

With [Wardrik](https://hexdocs.pm/wardrik), offer it by name, then list `web_search` in a
definition's `tools`:

```elixir
config :my_app, MyApp.AgentRuntime, capabilities: [web_search: {WardrikBrave, brave: MyApp.Brave}]
```

## Keys

- Each search uses `BRAVE_API_KEY` from the agent's `WardrikCore.Keys` first, then `:api_key`.
- If the agent's keys always hold it, skip the process: `{WardrikBrave, []}`.
- Keys are never saved with the agent's state.
- With no key, the search returns an error saying so.

## License

Apache-2.0
