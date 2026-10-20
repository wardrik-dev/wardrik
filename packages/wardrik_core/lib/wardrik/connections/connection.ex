defmodule Wardrik.Connections.Connection do
  @moduledoc """
  An account a deployment offers an owner: its provider, whether they hold
  it, as `Wardrik.Connections` says, and, as it is connected, where to
  authorize it, or `nil` where it is held already.
  """

  @enforce_keys [:provider, :connected]
  defstruct [:provider, :connected, authorization: nil]

  @type t() :: %__MODULE__{
          provider: String.t(),
          connected: boolean(),
          authorization: Wardrik.Call.Ask.link() | nil
        }
end
