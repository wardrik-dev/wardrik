defmodule Wardrik.MCPServer do
  @moduledoc """
  An MCP server an owner added for their agents: its `name`, its `url`, and how its agents sign in
  to it, `:oauth`, `:secret` or `:none`.
  """

  use Wardrik.Type,
    schema: ["server"],
    fields: [name: "name", url: "url", auth: {"auth", [:oauth, :secret, :none]}]
end

defmodule Wardrik.MCPServerAdded do
  @moduledoc """
  An MCP server just added: whether its agents can call it now, or the `authorization` where
  someone signs in to it first.
  """

  use Wardrik.Type,
    schema: ["server_added"],
    fields: [
      server: "server",
      connected: "connected",
      authorization: {"authorization", Wardrik.Authorization}
    ]
end
