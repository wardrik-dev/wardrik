# WardrikLua

Lua 5.3 for agents. The `run_lua` tool runs code an agent writes in a sealed sandbox and returns
the value: arithmetic, reshaping data, loops, or the current time.

```elixir
def deps do
  [
    {:wardrik_lua, "~> 0.1.0-rc.2"}
  ]
end
```

## Usage

Run the example in a fresh IEx session. Set `ANTHROPIC_API_KEY` before starting IEx.

```elixir
Mix.install([{:wardrik_lua, "~> 0.1.0-rc.2"}])

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "agt_triage",
    model: "anthropic:claude-haiku-4-5",
    capabilities: [{WardrikLua, limits: [timeout_ms: :timer.seconds(5)]}]
  )
```

With [Wardrik](https://hexdocs.pm/wardrik), offer it by name, then list `run_lua` in a definition's
`tools`:

```elixir
config :my_app, MyApp.AgentRuntime, capabilities: [run_lua: WardrikLua]
```

Enable `run_lua` in the agent's definition. Use the scope returned by your runtime's `as/2`:

```elixir
scope = MyApp.AgentRuntime.as("maria")

Wardrik.Agent.define(scope, "agt_triage",
  model: "anthropic:claude-haiku-4-5",
  tools: ["run_lua"]
)
```

See [Run Wardrik](https://hexdocs.pm/wardrik/running-wardrik.html) for runtime setup.

## The sandbox

- The VM is [lua](https://hexdocs.pm/lua), written in Elixir. It can't reach files, the network
  or the environment.
- `string`, `table`, `math`, `utf8`, `os.time` and `os.date` work. `io`, `require`, `load`,
  `os.execute` and the like raise.
- Each run has a deadline, a memory cap, a step cap and a call depth. See
  `WardrikLua.Sandbox.Limits`.

## License

Apache-2.0
