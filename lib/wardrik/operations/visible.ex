defmodule Wardrik.Operations.Visible do
  @moduledoc """
  Limits operations over many agents to what the scope may see.

  Only agents that the input's resource patterns cover, and the scope may act on, are shown. The
  same goes for their events and cursors.
  """

  alias Wardrik.Definitions
  alias Wardrik.Resource
  alias Wardrik.Scope
  alias WardrikEvents.Pattern

  @everything ["*"]

  @doc "Returns the IDs of saved or defined agents that `input`'s patterns cover and `scope` may see."
  @spec agents(Scope.t(), map()) :: [String.t()]
  def agents(%Scope{wardrik: wardrik} = scope, input) do
    (WardrikCore.list(Wardrik.agents(wardrik)) ++ Definitions.ids(wardrik))
    |> Enum.uniq()
    |> Enum.filter(&visible?(scope, patterns(input), &1))
    |> Enum.sort()
  end

  @doc "Returns the log patterns that hold every agent `input`'s patterns could cover."
  @spec logs(map()) :: [String.t()]
  def logs(input) do
    input
    |> patterns()
    |> Enum.map(&log_pattern/1)
    |> Enum.uniq()
  end

  @doc "Returns whether `patterns` cover the agent `id` and `scope` may see it."
  @spec visible?(Scope.t(), [String.t()], String.t()) :: boolean()
  def visible?(scope, patterns, id) do
    case Resource.agent(id) do
      {:ok, resource} ->
        Enum.any?(patterns, &Pattern.covers?(&1, resource)) and
          Wardrik.Authorizer.allows?(scope, resource)

      :error ->
        false
    end
  end

  @doc "Returns the ID of the agent whose log holds `event`."
  @spec agent_id(map()) :: String.t()
  def agent_id(%{"source" => source}) do
    [_deployment, id] = String.split(source, "/agents/", parts: 2)
    id
  end

  @doc ~S|Returns `input`'s `"resources"` patterns, or `["*"]`.|
  @spec patterns(map()) :: [String.t()]
  def patterns(input), do: Map.get(input, "resources", @everything)

  defp log_pattern(pattern) do
    case Pattern.org(pattern) do
      "*" -> "*"
      org -> org <> "/*"
    end
  end
end
