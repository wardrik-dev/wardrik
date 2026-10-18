# Workflows

Workflows for Wardrik agents: steps run many at once or one
after another, each under a span of its own, and offered to an agent as a
tool.

A workflow is a `WardrikWorkflow.Step`, and becomes a tool when an agent
should be able to call it:

```elixir
defmodule MyApp.Nightly do
  @behaviour Wardrik.Tool
  @behaviour WardrikWorkflow.Step

  @impl Wardrik.Tool
  def tool do
    WardrikWorkflow.as_tool(__MODULE__,
      name: "nightly",
      description: "Summarise everything that changed since a date.",
      parameter_schema: [since: [type: :string, required: true, doc: "ISO date"]]
    )
  end

  @impl WardrikWorkflow.Step
  def run(%{since: since}, run, _opts) do
    run
    |> WardrikWorkflow.fan_out(repos(), fn repo, branch ->
      Wardrik.Subagent.run(branch, "What changed in #{repo} since #{since}?", except_tools: ["nightly"])
    end)
    |> report()
  end
end
```

`fan_out/4` runs a step over many inputs at once, under a task supervisor of
its own linked to the caller, and reports one outcome per input. `sequence/3`
feeds each step the one before it and stops at the first error. A branch's
events land in the agent's stream under its own span, and the labels of what
its delegates read reach the process that fanned out.
