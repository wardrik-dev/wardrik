defmodule WardrikResearch do
  @moduledoc """
  Deep research for agents, as the `deep_research` tool.

      WardrikCore.start_agent(
        agent_id: "agt_analyst",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [
          {WardrikBrave, brave: MyApp.Brave},
          {WardrikResearch, angles: [%{angle: "pricing", prompt: "Think like an analyst."}]}
        ]
      )

    * Each angle gets a subagent on the agent's model, middleware and tools.
    * Give the agent a search tool, or research only knows what the model knows.
    * A failed angle is reported as a gap. The call fails only when every angle does.

  ## Options

    * `:angles` - each `%{angle: name}`, with an optional `:prompt` for that researcher. Five
      general angles unless set. The agent may pass its own for one call.
    * `:max_concurrency` - researchers running at once. `5` unless set.
    * `:timeout` - milliseconds one researcher may take. 8 minutes unless set.
    * `:max_rounds` - model calls one researcher may make. `12` unless set.
  """

  @behaviour WardrikCore.Capability

  @impl WardrikCore.Capability
  def tools(_context, opts), do: [WardrikResearch.Deep.tool(opts)]
end
