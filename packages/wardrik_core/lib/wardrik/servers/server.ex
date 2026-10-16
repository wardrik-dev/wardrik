defmodule Wardrik.Servers.Server do
  @moduledoc """
  An MCP server an owner added: its name, its URL, how its agents sign in to
  it, as a word: `oauth`, `secret` or `none`, with the name of the vault's
  secret for `secret`, and, as it is added, where someone signs in to it
  before its agents can call it, or `nil` where they can call it now.
  """

  @enforce_keys [:name, :url, :auth]
  defstruct [:name, :url, :auth, secret: nil, authorization: nil]

  @type t() :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          auth: String.t(),
          secret: String.t() | nil,
          authorization: Wardrik.Call.Ask.link() | nil
        }
end
