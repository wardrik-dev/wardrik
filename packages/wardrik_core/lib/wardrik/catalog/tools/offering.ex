defmodule Wardrik.Catalog.Tools.Offering do
  @moduledoc """
  One of the catalog's operations offered as a tool to an agent, as far as
  its reach goes: the operation's module, what runs it, `Wardrik.Query` or
  `Wardrik.Command`, as the catalog's lists say, and the agents the calling
  agent reaches with it.
  See `Wardrik.Catalog.Tools`.
  """

  @enforce_keys [:module, :runner, :reach]
  defstruct [:module, :runner, :reach]

  @type t() :: %__MODULE__{
          module: module(),
          runner: Wardrik.Query | Wardrik.Command,
          reach: Wardrik.AgentID.Prefix.t()
        }
end
