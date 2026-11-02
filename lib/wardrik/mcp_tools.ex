defmodule Wardrik.MCPTools do
  @moduledoc """
  Gives an agent the tools of the MCP servers it names. Implements `WardrikCore.Capability`.

  A name reaches the server the agent is resolved with by that name, and nothing else. See
  `Wardrik.Resolver`. With `all: true`, the agent gets every server it's resolved with.

  Servers are resolved at the start of each turn, so added or removed servers apply from the
  next turn.
  """

  @behaviour WardrikCore.Capability

  @impl WardrikCore.Capability
  def tools(%WardrikCore.Context{agent_id: id} = context, opts) do
    mcp = Keyword.fetch!(opts, :mcp)
    WardrikMCP.tools(context, name: mcp, servers: picked(mcp, resolved(id, opts), opts))
  end

  defp resolved(id, opts) do
    wardrik = Wardrik.Instance.fetch!(Keyword.fetch!(opts, :wardrik))

    case Wardrik.Resolver.resolve(wardrik, %Wardrik.Resolver.Request{
           agent: id,
           definition: Keyword.fetch!(opts, :definition)
         }) do
      {:ok, resolved} -> resolved.servers
      {:error, _error} -> %{}
    end
  end

  @doc """
  Returns the `WardrikMCP` names of the servers `opts` reach that are up, of `servers`, those the
  agent is resolved with.
  """
  @spec picked(atom(), %{String.t() => String.t()}, keyword()) :: [String.t()]
  def picked(mcp, servers, opts) do
    available = MapSet.new(WardrikMCP.servers(mcp))
    keys = if Keyword.get(opts, :all, false), do: Map.values(servers), else: named(servers, opts)
    for key <- Enum.uniq(keys), MapSet.member?(available, key), do: key
  end

  defp named(servers, opts) do
    for name <- Keyword.get(opts, :names, []), {:ok, key} <- [Map.fetch(servers, name)], do: key
  end

  @doc """
  Returns the `WardrikMCP` name of the server `name` that `owner` added.

      Wardrik.MCPTools.key("acme", "github")
      #=> "acme:github"
  """
  @spec key(String.t(), String.t()) :: String.t()
  def key(owner, name), do: owner <> ":" <> name

  @doc "Returns Wardrik's own servers that serve `org`, as configured. Every one for `nil`."
  @spec serving(Wardrik.t(), String.t() | nil) :: keyword()
  def serving(wardrik, org),
    do: for({_name, opts} = server <- wardrik.mcp, serves?(opts[:orgs], org), do: server)

  defp serves?(nil, _org), do: true
  defp serves?(_orgs, nil), do: true
  defp serves?(orgs, org), do: org in orgs
end
