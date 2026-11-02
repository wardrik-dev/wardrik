defmodule Wardrik.Declarations do
  @moduledoc """
  Agents defined outside the API, such as agent files.

      Wardrik.start_link(name: MyApp.AgentRuntime, declarations: {MyApp.AgentFiles, dir: "agents"})

    * The API won't forget a declared agent.
    * `Wardrik.Deployment.reload/2` reloads declarations first.
  """

  @doc "Returns whether `agent_id` is declared."
  @callback declared?(config :: term(), agent_id :: String.t()) :: boolean()

  @doc "Defines the declared agents again. Returns a line for each failure."
  @callback reload(config :: term()) :: [String.t()]

  @doc "Returns whether `agent_id` is declared."
  @spec declared?(Wardrik.t(), String.t()) :: boolean()
  def declared?(%Wardrik{declarations: nil}, _agent_id), do: false

  def declared?(%Wardrik{declarations: {module, config}}, agent_id),
    do: module.declared?(config, agent_id)

  @doc "Reloads the declarations, if any. Returns a line for each failure."
  @spec reload(Wardrik.t()) :: [String.t()]
  def reload(%Wardrik{declarations: nil}), do: []
  def reload(%Wardrik{declarations: {module, config}}), do: module.reload(config)
end
