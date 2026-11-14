defmodule WardrikCore.Configure do
  @moduledoc """
  Gives an agent its settings again as it loads, after a restart or on another node.

  An agent keeps its conversation and the turn it was in, never how it's configured: its
  instructions, model, capabilities, middleware and the rest of `WardrikCore.start_agent/2`'s
  options. Those are your code's, so they're read again each time it loads.

      {WardrikCore, backend: backend, configure: {MyApp.Agents, []}}

      defmodule MyApp.Agents do
        @behaviour WardrikCore.Configure

        @impl true
        def configure({agent_id, _conversation}, _opts) do
          case MyApp.Agents.definition(agent_id) do
            nil -> :none
            definition -> {:ok, [model: definition.model, instructions: definition.prompt]}
          end
        end
      end

  An agent with no settings to load waits, its queue kept, until `WardrikCore.start_agent/2` or
  `WardrikCore.configure/2` gives it some.
  """

  @doc """
  Returns `WardrikCore.start_agent/2`'s options for the agent `key`, but `:agent_id` and
  `:conversation`, or `:none`.
  """
  @callback configure(WardrikCore.key(), opts :: term()) :: {:ok, keyword()} | :none
end
