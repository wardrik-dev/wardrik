defmodule Wardrik.Tokens.Entry do
  @moduledoc """
  A token as the host keeps it: its id and name, the `Wardrik.Token` it
  presents, and when it was made. `secret` is set only on the entry
  `Wardrik.Tokens.create/3` answers, the one time it is given, and is never
  inspected.
  """

  @derive {Inspect, except: [:secret]}
  @enforce_keys [:id, :name, :token, :created_at]
  defstruct [:id, :name, :token, :created_at, secret: nil]

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          token: Wardrik.Token.t(),
          created_at: DateTime.t(),
          secret: String.t() | nil
        }
end
