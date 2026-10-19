defmodule Wardrik.ByOrg do
  @moduledoc "A context for each org's agents, by org."

  @enforce_keys [:contexts]
  defstruct [:contexts]

  defimpl WardrikDefinition.Contexts do
    def context(%{contexts: contexts}, %Wardrik.AgentID{org: org}), do: Map.fetch!(contexts, org)
    def reload(_by_org, _opts), do: []
  end
end
