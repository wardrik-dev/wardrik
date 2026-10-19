defmodule Wardrik.Connections.Connection do
  @moduledoc """
  An account a deployment offers an owner: its provider, what holds it for
  them, `:own`, `:shared` or `:none`, as `Wardrik.Connections` says, and, as
  it is connected, where to authorize it, or `nil` where it is held already.
  """

  @enforce_keys [:provider, :held_by]
  defstruct [:provider, :held_by, authorization: nil]

  @type t() :: %__MODULE__{
          provider: String.t(),
          held_by: Wardrik.Connections.held_by(),
          authorization: Wardrik.Call.Ask.link() | nil
        }
end
