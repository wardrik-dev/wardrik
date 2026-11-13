defmodule Wardrik.Connection do
  @moduledoc """
  An account the caller can connect.

    * `:provider` - its name: an OAuth app's, or an MCP server's that makes its own sign-in.
    * `:connected` - whether the caller holds it.
    * `:signing_in` - whether a sign-in the caller started is under way.
  """

  use Wardrik.Type,
    schema: ["connection"],
    fields: [provider: "provider", connected: "connected", signing_in: "signing_in"]
end
