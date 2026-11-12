# WardrikCore

Runs agents with persistent state, tool call approvals, and middleware for model and tool calls.

## Install

```elixir
def deps do
  [
    {:wardrik_core, "~> 0.1.0-rc.6"}
  ]
end
```

## Start an agent

Set `ANTHROPIC_API_KEY` before starting `iex`.

```elixir
Mix.install([{:wardrik_core, "~> 0.1.0-rc.6"}])

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, agent} = WardrikCore.start_agent(agent_id: "triage", model: "anthropic:claude-haiku-4-5")
:ok = WardrikCore.ask(agent, "What's on fire?")
```

`MemoryStore` loses agents when the node stops. To keep them, see
[Agent storage](pages/running-agents.md#agent-storage).

## Guides

- [Run agents](pages/running-agents.md): start, control and keep agents.
- [Tools](pages/tools.md): give an agent tools.
- [Middleware](pages/middleware.md): wrap every call, or wait for a person.
- [Who sent a message](pages/principals.md): act for the person who asked.
- [Credentials](pages/credentials.md): use a person's tokens and your own API keys.
- [Tracing](pages/tracing.md): spans, attributes and measurements.
- [Events](pages/events.md): follow an agent from a CLI or a web page.

Policy, MCP servers, secret storage, OAuth, event logs and HTTP live in other `wardrik_*` packages.

## License

Apache-2.0
