defmodule Wardrik.MCPTools do
  @moduledoc """
  The tools of the MCP servers an agent names, found as each turn starts: its owner's own server of
  each name first, then its org's, then the one Wardrik started with, where that one serves its
  org. With `all`, every server its owner adds too. A server added or removed reaches the agent
  from its next turn.
  """

  @behaviour WardrikCore.Capability

  alias Wardrik.Definition

  @impl WardrikCore.Capability
  def tools(%WardrikCore.Context{agent_id: id} = context, opts) do
    mcp = Keyword.fetch!(opts, :mcp)
    WardrikMCP.tools(context, name: mcp, servers: picked(mcp, id, opts))
  end

  @doc "Returns the servers the agent `id` reaches for what it names in `opts`, as `WardrikMCP` names them."
  @spec picked(atom(), String.t(), keyword()) :: [String.t()]
  def picked(mcp, id, opts) do
    available = MapSet.new(WardrikMCP.servers(mcp))
    owners = owners(id)
    served = Keyword.get(opts, :served, :all)
    named = Enum.flat_map(Keyword.get(opts, :names, []), &first(available, owners, served, &1))
    Enum.uniq(named ++ owned(available, owners, Keyword.get(opts, :all, false)))
  end

  @doc "Returns the name `WardrikMCP` knows the server `name` that `owner` added by."
  @spec key(String.t(), String.t()) :: String.t()
  def key(owner, name), do: owner <> ":" <> name

  @doc "Returns the owners whose servers the agent `id` reaches, its own first: a person, then their org."
  @spec owners(String.t()) :: [String.t()]
  def owners(id) do
    case Definition.principal(id).id do
      owner when owner != "" -> [owner | org(owner)]
    end
  end

  defp org(owner) do
    case String.split(owner, "/") do
      [org, _user] -> [org]
      [_org] -> []
    end
  end

  @doc """
  Returns the names of the servers the Wardrik started with that the agent `id`'s org reaches: each
  whose `:orgs` lists it, or that has none.
  """
  @spec served(Wardrik.t(), String.t()) :: [String.t()]
  def served(wardrik, id) do
    org = Wardrik.Orgs.org(id)
    for {name, opts} <- wardrik.mcp || [], serves?(opts[:orgs], org), do: to_string(name)
  end

  defp serves?(nil, _org), do: true
  defp serves?(orgs, org), do: org in orgs

  defp first(available, owners, served, name) do
    owners
    |> Enum.map(&key(&1, name))
    |> Kernel.++(started(served, name))
    |> Enum.find(&MapSet.member?(available, &1))
    |> List.wrap()
  end

  defp started(:all, name), do: [name]
  defp started(served, name), do: if(name in served, do: [name], else: [])

  defp owned(_available, _owners, false), do: []

  defp owned(available, owners, true) do
    owners
    |> Enum.flat_map(fn owner ->
      Enum.filter(available, &String.starts_with?(&1, owner <> ":"))
    end)
    |> Enum.uniq_by(fn key -> key |> String.split(":", parts: 2) |> List.last() end)
  end
end
