defmodule Wardrik.Servers do
  @moduledoc """
  Operations on the MCP servers an owner keeps for agents.

      Wardrik.Servers.add(scope, "acme", name: "crm", url: "https://crm.example/mcp", auth: %{none: %{}})
      #=> {:ok, %Wardrik.ServerAdded{server: "crm", connected: true}}

  Your resolver gives each agent the servers it reaches. Using another owner's is
  `mcp_server.use` on `{:mcp_server, owner}`, as your authorizer decides.
  """

  use Wardrik.Operations.Functions, prefix: "servers"
end
