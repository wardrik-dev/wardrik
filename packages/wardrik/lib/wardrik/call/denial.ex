defmodule Wardrik.Call.Denial do
  @moduledoc """
  Why a `Wardrik.Call` may not go ahead, and who said so: the name of the
  `Wardrik.Hook` that refused it, `:person` for one a person refused, or `:ledger`
  for one the ledger could not record before it ran.
  """

  @enforce_keys [:by, :reason]
  defstruct [:by, :reason]

  @type t() :: %__MODULE__{by: String.t() | :person | :ledger, reason: String.t()}
end
