defmodule Wardrik.MCP.Capability do
  @moduledoc false

  @behaviour WardrikCore.Capability

  @impl WardrikCore.Capability
  def tools(%WardrikCore.Context{agent_id: id} = context, opts) do
    mcp = Keyword.fetch!(opts, :mcp)
    Wardrik.MCP.tools(context, name: mcp, servers: picked(mcp, resolved(id, opts), opts))
  end

  defp resolved(id, opts) do
    instance = Keyword.fetch!(opts, :wardrik)
    wardrik = Wardrik.Instance.fetch!(instance)

    case Wardrik.Resolver.resolve(wardrik, %Wardrik.Resolver.Request{
           agent: id,
           definition: Keyword.fetch!(opts, :definition)
         }) do
      {:ok, resolved} -> resolved.servers
      {:error, _error} -> %{}
    end
  end

  @doc """
  Returns the `Wardrik.MCP` names of the servers `opts` reach that are up.
  """
  @spec picked(atom(), %{String.t() => String.t()}, keyword()) :: [String.t()]
  def picked(mcp, servers, opts) do
    available =
      mcp
      |> Wardrik.MCP.servers()
      |> MapSet.new()

    keys = if Keyword.get(opts, :all, false), do: Map.values(servers), else: named(servers, opts)
    for key <- Enum.uniq(keys), MapSet.member?(available, key), do: key
  end

  defp named(servers, opts) do
    for name <- Keyword.get(opts, :names, []), {:ok, key} <- [Map.fetch(servers, name)], do: key
  end
end
