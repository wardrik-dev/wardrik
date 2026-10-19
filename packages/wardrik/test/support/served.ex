defmodule WardrikDefinition.Test.Served do
  @moduledoc false
  # A server a host configures, as a source a definition names as
  # `name/*`: it gives `{source, deployment/server/name}` to the agents its
  # patterns cover, and refuses the others, as an MCP server serving some
  # orgs does.

  alias Wardrik.AgentID
  alias Wardrik.Resource

  @enforce_keys [:name, :source]
  defstruct [:name, :source, serves: [Resource.parse!("*")]]

  defimpl WardrikDefinition.Source do
    def spec(%{name: name, source: source, serves: serves}, id) do
      if Enum.any?(serves, &Resource.covers?(&1, AgentID.resource(id))),
        do: {:ok, {source, Resource.new(Resource.deployment(), server: name)}},
        else: {:error, "#{name} serves #{Enum.join(serves, ", ")}, and not #{id}"}
    end
  end
end
