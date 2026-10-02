# wardrik_lua

Lua 5.3 for [Wardrik](../wardrik) agents: a sandbox for code an agent writes,
and the `run_lua` tool that runs it there. It is how an agent does work no
other tool covers, such as arithmetic over numbers it holds, reshaping a
result or a loop.

```elixir
def deps do
  [{:wardrik_lua, "~> 0.1.0"}]
end
```

```elixir
Wardrik.LLM.Config.new(tools: [WardrikLua.Run])
```

The VM is written in Elixir and reaches nothing outside itself: no files, no
network, no environment, and nothing else the agent has. Each run is checked,
then evaluated in a task of its own under `Wardrik.Sandbox.Limits`, a
deadline, a memory budget, a step budget and a call depth:

```elixir
WardrikLua.Run.tool(limits: Wardrik.Sandbox.Limits.new(timeout_ms: :timer.seconds(5)))
```

`WardrikLua.Sandbox` implements `Wardrik.Sandbox`, so the same limits bound
any other language a sandbox of your own implements.
