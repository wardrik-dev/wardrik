defmodule Wardrik.Servers.Server do
  @moduledoc """
  An MCP server an owner added: its name, its URL, how its agents sign in to
  it, as a word: `oauth`, `secret` or `none`, and, as it is added, where
  someone signs in to it before its agents can call it, or `nil` where they
  can call it now.

  How it signs in says more for some words, and is `nil` where it says
  nothing:

    * `secret` - the name of the vault's `secret`, sent in the `header`
      after the `scheme`, `authorization` and `Bearer` by default
    * `oauth` - the `scopes` to ask for, the server's own by default

  `only` and `except` are the server's own names of the tools its agents
  take, and leave; every one by default.
  """

  @enforce_keys [:name, :url, :auth]
  defstruct [
    :name,
    :url,
    :auth,
    secret: nil,
    header: nil,
    scheme: nil,
    scopes: nil,
    only: nil,
    except: nil,
    authorization: nil
  ]

  @type t() :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          auth: String.t(),
          secret: String.t() | nil,
          header: String.t() | nil,
          scheme: String.t() | nil,
          scopes: [String.t()] | nil,
          only: [String.t()] | nil,
          except: [String.t()] | nil,
          authorization: Wardrik.Call.Ask.link() | nil
        }
end
