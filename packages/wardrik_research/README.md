# wardrik_research

Deep research for [Wardrik](../wardrik) agents. A topic is split across
angles, a researcher takes each one, and what they found is combined into one
answer.

```elixir
def deps do
  [{:wardrik_research, "~> 0.1.0"}]
end
```

```elixir
Wardrik.LLM.Config.new(tools: [WardrikBrave.WebSearch, WardrikResearch.Deep])
```

The agent calls it as `deep_research`. Researchers run with the calling
agent's model and tools, minus this one, so you decide what research can
reach by choosing the agent's tools. Give it a search tool such as
[wardrik_brave](../wardrik_brave), or research is limited to what the model
already knows.

Angles can be chosen for your deployment:

```elixir
WardrikResearch.Deep.tool(
  angles: [
    %{angle: "pricing and packaging", prompt: "Think like a pricing analyst."},
    %{angle: "recent developments"}
  ]
)
```

It is also a `Wardrik.Workflow.Step`, so you can run it yourself, or inside a
larger workflow:

```elixir
WardrikResearch.Deep.run(%{topic: "the WASM component model"}, scope, [])
```
