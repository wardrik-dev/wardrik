defmodule Wardrik.Connections.Connecting do
  @moduledoc """
  An account asked for: the provider, and where to authorize it, or `nil`
  where it is held already.
  """

  @enforce_keys [:provider, :authorization]
  defstruct [:provider, :authorization]

  @type t() :: %__MODULE__{provider: String.t(), authorization: Wardrik.Call.Ask.link() | nil}
end
