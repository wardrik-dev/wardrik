defmodule Wardrik.Servers.Added do
  @moduledoc """
  An MCP server an owner added: its name, and where someone signs in to it
  before its agents can call it, or `nil` where they can call it now.
  """

  @enforce_keys [:name, :authorization]
  defstruct [:name, :authorization]

  @type t() :: %__MODULE__{name: String.t(), authorization: Wardrik.Call.Ask.link() | nil}
end
