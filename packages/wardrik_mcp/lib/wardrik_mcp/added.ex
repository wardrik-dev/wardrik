defmodule WardrikMCP.Added do
  @moduledoc """
  Every MCP server an agent's owner added, as one tool source: the tools of
  each, as `WardrikMCP` offers them. A host names it among the sources a
  definition may name, so a definition asking for `servers/*` reaches
  whatever its owner adds, as they add it:

      %WardrikDefinition.Context{mcp: WardrikMCP, sources: [servers: WardrikMCP.Added]}

  It is handed the agent's ID and reaches its owner's servers alone: an
  org's own agents the org's, and a person's agents that person's.
  """

  @behaviour Wardrik.Tool

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias WardrikMCP.Remotes

  @doc "The tools of every server the owner of the agent `id` added."
  @impl Wardrik.Tool
  def tools(%AgentID{} = id), do: id |> keys() |> Enum.flat_map(&WardrikMCP.tools/1)

  @doc """
  What holds for the tool `name`, as `WardrikMCP.annotations/2` says for
  the server offering it; one no server of the owner's offers any more waits
  on a person, and is labelled `"outside"`, as every owner's server's answers
  are.
  """
  @impl Wardrik.Tool
  def annotations(%AgentID{} = id, name) do
    case Enum.filter(keys(id), &offers?(&1, name)) do
      [key | _rest] -> WardrikMCP.annotations(key, name)
      [] -> %{gated: true, labels: ["outside"]}
    end
  end

  defp keys(id), do: id |> Prefix.owner() |> Remotes.added()

  defp offers?(key, name), do: Enum.any?(WardrikMCP.tools(key), &(&1.name == name))
end
