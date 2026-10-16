defmodule Wardrik.Tokens.Issued do
  @moduledoc """
  A token just made: its secret, given this once and kept nowhere, and the
  token as the host keeps it.
  """

  @enforce_keys [:secret, :token]
  defstruct [:secret, :token]

  @type t() :: %__MODULE__{secret: String.t(), token: Wardrik.Tokens.token()}
end
