defmodule Wardrik.Servers.Listed do
  @moduledoc """
  A server an owner added, as `Wardrik.Servers.list/2` answers it: its name,
  its URL, and how its agents sign in to it, as a word: `oauth`, `secret` or
  `none`.
  """

  @enforce_keys [:name, :url, :auth]
  defstruct [:name, :url, :auth]

  @type t() :: %__MODULE__{name: String.t(), url: String.t(), auth: String.t()}
end
