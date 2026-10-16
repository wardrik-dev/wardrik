defmodule Wardrik.Connections.Connection do
  @moduledoc """
  An account a deployment offers an owner: its provider, who holds it for
  them, `:person`, `:org`, `:deployment` or `nil` for nobody, and, as it is
  connected, where to authorize it, or `nil` where it is held already.
  """

  @enforce_keys [:provider, :held_by]
  defstruct [:provider, :held_by, authorization: nil]

  @type t() :: %__MODULE__{
          provider: String.t(),
          held_by: Wardrik.Connections.held_by(),
          authorization: Wardrik.Call.Ask.link() | nil
        }
end
