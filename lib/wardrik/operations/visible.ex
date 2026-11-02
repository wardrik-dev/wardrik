defmodule Wardrik.Operations.Visible do
  @moduledoc """
  Limits operations over many agents to what the scope may see.

  Only the agents the input's `"agents"` names, or every agent without it, that the authorizer
  lets the scope act on are shown. The same goes for their events and cursors.
  """

  alias Wardrik.Definitions
  alias Wardrik.Scope

  @doc "Returns the IDs of saved or defined agents that `input` names and `scope` may see."
  @spec agents(Scope.t(), map()) :: [String.t()]
  def agents(%Scope{wardrik: wardrik} = scope, input) do
    (WardrikCore.list(Wardrik.agents(wardrik)) ++ Definitions.ids(wardrik))
    |> Enum.uniq()
    |> Enum.filter(&visible?(scope, input, &1))
    |> Enum.sort()
  end

  @doc "Returns the log patterns that hold every agent `input` names."
  @spec logs(map()) :: [String.t()]
  def logs(%{"agents" => ids}), do: Enum.uniq(ids)
  def logs(_input), do: ["*"]

  @doc "Returns whether `input` names the agent `id`, and `scope` may see it."
  @spec visible?(Scope.t(), map(), String.t()) :: boolean()
  def visible?(scope, input, id),
    do: named?(input, id) and Wardrik.Authorizer.allows?(scope, {:agent, id})

  @doc "Returns the ID of the agent whose log holds `event`."
  @spec agent_id(map()) :: String.t()
  def agent_id(%{"source" => source}) do
    [_deployment, id] = String.split(source, "/agents/", parts: 2)
    id
  end

  defp named?(%{"agents" => ids}, id), do: id in ids
  defp named?(_input, _id), do: true
end
