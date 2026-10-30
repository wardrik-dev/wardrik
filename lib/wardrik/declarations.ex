defmodule Wardrik.Declarations do
  @moduledoc """
  Agents defined outside the API, such as agent files a daemon reads.

      Wardrik.start_link(name: MyApp.Wardrik, declarations: {MyApp.AgentFiles, dir: "agents"})

  The API refuses to forget a declared agent, since its declaration would bring it back.
  `Wardrik.Deployment.reload/2` reloads declarations before it updates agents to their definitions.
  """

  @doc "Returns whether `agent_id` is declared. The API won't forget a declared agent."
  @callback declared?(config :: term(), agent_id :: String.t()) :: boolean()

  @doc "Reads the declarations again and defines their agents. Returns a line for each failure."
  @callback reload(config :: term()) :: [String.t()]

  @doc "Returns whether `agent_id` is declared."
  @spec declared?(Wardrik.t(), String.t()) :: boolean()
  def declared?(%Wardrik{declarations: nil}, _agent_id), do: false

  def declared?(%Wardrik{declarations: {module, config}}, agent_id),
    do: module.declared?(config, agent_id)

  @doc "Reloads the declarations, if any. Returns a line for each agent that couldn't be defined."
  @spec reload(Wardrik.t()) :: [String.t()]
  def reload(%Wardrik{declarations: nil}), do: []
  def reload(%Wardrik{declarations: {module, config}}), do: module.reload(config)
end
