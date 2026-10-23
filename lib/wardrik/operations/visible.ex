defmodule Wardrik.Operations.Visible do
  @moduledoc """
  What an operation over many agents shows: the agents its resource patterns cover that the scope
  may act on, and of their events and cursors only theirs.
  """

  alias Wardrik.Definitions
  alias Wardrik.Resource
  alias Wardrik.Scope
  alias WardrikEvents.Pattern

  @everything ["*"]

  @doc "Returns the IDs of the agents, saved or defined, that `input`'s patterns cover and `scope` reaches."
  @spec agents(Scope.t(), map()) :: [String.t()]
  def agents(%Scope{wardrik: wardrik} = scope, input) do
    (WardrikCore.list(Wardrik.agents(wardrik)) ++ Definitions.ids(wardrik))
    |> Enum.uniq()
    |> Enum.filter(&visible?(scope, patterns(input), &1))
    |> Enum.sort()
  end

  @doc "Returns the patterns of the logs that hold every agent `input`'s patterns could cover."
  @spec logs(map()) :: [String.t()]
  def logs(input) do
    input
    |> patterns()
    |> Enum.map(&log_pattern/1)
    |> Enum.uniq()
  end

  @doc "Returns whether `scope` may see the agent `id`, among those `patterns` cover."
  @spec visible?(Scope.t(), [String.t()], String.t()) :: boolean()
  def visible?(scope, patterns, id) do
    case Resource.agent(id) do
      {:ok, resource} ->
        Enum.any?(patterns, &Pattern.covers?(&1, resource)) and Scope.allows?(scope, resource)

      :error ->
        false
    end
  end

  @doc "Returns the ID of the agent whose log `event` is in."
  @spec agent_id(map()) :: String.t()
  def agent_id(%{"source" => source}) do
    [_deployment, id] = String.split(source, "/agents/", parts: 2)
    id
  end

  @doc "Returns `input`'s resource patterns, or every resource."
  @spec patterns(map()) :: [String.t()]
  def patterns(input), do: Map.get(input, "resources", @everything)

  defp log_pattern(pattern) do
    case Pattern.org(pattern) do
      "*" -> "*"
      org -> org <> "/*"
    end
  end
end
