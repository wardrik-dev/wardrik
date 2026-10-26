defmodule Wardrik.Declarations do
  @moduledoc """
  Declarations are agents something outside the API defines, such as agent files a daemon reads.
  A Wardrik takes them as `declarations: {module, config}`. Forgetting a declared agent over the
  API is refused, since its declaration would bring it back, and `Wardrik.Deployment.reload/2`
  reads them again before it brings agents to their definitions.
  """

  @doc "Returns whether `agent_id` is declared, so the API may not forget it."
  @callback declared?(config :: term(), agent_id :: String.t()) :: boolean()

  @doc "Reads the declarations again, and defines what they declare."
  @callback reload(config :: term()) :: :ok

  @doc "Returns whether the Wardrik's declarations declare `agent_id`."
  @spec declared?(Wardrik.t(), String.t()) :: boolean()
  def declared?(%Wardrik{declarations: nil}, _agent_id), do: false

  def declared?(%Wardrik{declarations: {module, config}}, agent_id),
    do: module.declared?(config, agent_id)

  @doc "Reads the Wardrik's declarations again, where it has any."
  @spec reload(Wardrik.t()) :: :ok
  def reload(%Wardrik{declarations: nil}), do: :ok
  def reload(%Wardrik{declarations: {module, config}}), do: module.reload(config)
end
