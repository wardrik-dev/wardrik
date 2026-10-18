defmodule WardrikMCP.Offer do
  @moduledoc """
  What one MCP server is offering right now: the server as it is configured,
  the tools it last reported, and the remote names of those it marked
  `readOnlyHint`.

  Held as the registry value under `{:offer, key}` by `WardrikMCP.Connection`, so
  building a turn's tools and calling one read the same place and neither waits
  on a process.
  """

  alias WardrikMCP.Server

  @enforce_keys [:server]
  defstruct [:server, tools: [], read_only: []]

  @typedoc "A server, the tools it last reported, and those it marked read-only."
  @type t() :: %__MODULE__{
          server: Server.t(),
          tools: [Wardrik.Tool.t()],
          read_only: [String.t()]
        }
end
