defmodule Wardrik.MCPServer do
  @moduledoc """
  An MCP server an owner keeps, never with its headers.

    * `:owner` - who keeps it, as your app names them, or `"deployment"`.
    * `:name` - what its agents call it: its tools are `name__tool`.
    * `:source` - `:config` for one the deployment starts with, `:runtime` for one added since.
    * `:url` - its URL, or `nil` for a command the deployment starts.
    * `:auth` - how its agents sign in to it: `:oauth`, `:secret` or `:none`.
  """

  use Wardrik.Type,
    schema: ["server"],
    fields: [
      owner: "owner",
      name: "name",
      source: {"source", [:config, :runtime]},
      url: "url",
      auth: {"auth", [:oauth, :secret, :none]}
    ]
end
