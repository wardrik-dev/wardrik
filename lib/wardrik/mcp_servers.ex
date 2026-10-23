defmodule Wardrik.MCPServers do
  @moduledoc """
  The MCP servers an org or a person adds for their agents as the app runs.

      {:ok, %Wardrik.MCPServerAdded{connected: true}} =
        Wardrik.MCPServers.add(scope, owner: "acme", name: "docs", url: "https://docs.example.com/mcp", auth: %{none: %{}})
  """

  use Wardrik.Operations.Functions, prefix: "mcp_servers"
end
