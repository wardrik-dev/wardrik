defmodule WardrikMCP.Offer do
  @moduledoc """
  What one MCP server is offering right now: the server as it is configured,
  and the tools it last reported.

  Held as the registry value under `{:offer, ref}` by `WardrikMCP.Connection`, so
  building a turn's tools and calling one read the same place and neither waits
  on a process.
  """

  alias WardrikMCP.Server

  @enforce_keys [:server]
  defstruct [:server, tools: []]

  @typedoc "A server, and the tools it last reported."
  @type t() :: %__MODULE__{
          server: Server.t(),
          tools: [ReqLLM.Tool.t()]
        }
end
