defmodule Wardrik.MCPTools do
  @moduledoc """
  Gives an agent the tools of the MCP servers it names. Implements `WardrikCore.Capability`.

  Servers are looked up at the start of each turn, so added or removed servers apply from the
  next turn. For each name, the first match wins:

    1. The owner's server of that name.
    2. The org's, for a person's agent.
    3. The deployment's, added at runtime.
    4. The server Wardrik started with, if it serves the agent's org.

  With `all: true`, the agent also gets every server its owners added. See `Wardrik.Owners`.
  """

  @behaviour WardrikCore.Capability

  alias Wardrik.Definition
  alias Wardrik.Owners

  @impl WardrikCore.Capability
  def tools(%WardrikCore.Context{agent_id: id} = context, opts) do
    mcp = Keyword.fetch!(opts, :mcp)
    WardrikMCP.tools(context, name: mcp, servers: picked(mcp, id, opts))
  end

  @doc "Returns the `WardrikMCP` names of the servers the agent `id` gets for `opts`."
  @spec picked(atom(), String.t(), keyword()) :: [String.t()]
  def picked(mcp, id, opts) do
    available = MapSet.new(WardrikMCP.servers(mcp))
    owners = owners(id)
    served = Keyword.get(opts, :served, :all)
    named = Enum.flat_map(Keyword.get(opts, :names, []), &first(available, owners, served, &1))
    Enum.uniq(named ++ owned(available, owners, Keyword.get(opts, :all, false)))
  end

  @doc """
  Returns the `WardrikMCP` name of the server `name` that `owner` added.

      Wardrik.MCPTools.key("acme", "github")
      #=> "acme:github"
  """
  @spec key(String.t(), String.t()) :: String.t()
  def key(owner, name), do: owner <> ":" <> name

  @doc "Returns the owners whose servers the agent `id` can use, nearest first."
  @spec owners(String.t()) :: [String.t()]
  def owners(id), do: Owners.chain(Definition.principal(id).id)

  @doc """
  Returns the names of Wardrik's own servers that serve the agent `id`'s org.

  A server serves an org if its `:orgs` lists it, or it has no `:orgs`.
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
