defmodule Wardrik.ServerAdded do
  @moduledoc """
  What adding an MCP server answers.

    * `:server` - its name.
    * `:connected` - whether its agents can call it now.
    * `:authorization` - where someone signs in to it first, or `nil`.
  """

  use Wardrik.Type,
    schema: ["server_added"],
    fields: [server: "server", connected: "connected", authorization: "authorization"]
end
