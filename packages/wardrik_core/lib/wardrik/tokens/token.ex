defmodule Wardrik.Tokens.Token do
  @moduledoc """
  A token as the host keeps it: its `grant`, the `principal` it acts for, or
  `nil` for itself, and when it was made. `secret` is set only on the token
  `Wardrik.Tokens.create/3` answers, the one time it is given, and is never
  inspected.
  """

  @derive {Inspect, except: [:secret]}
  @enforce_keys [:id, :name, :grant, :principal, :created_at]
  defstruct [:id, :name, :grant, :principal, :created_at, secret: nil]

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          grant: Wardrik.Grant.t(),
          principal: Wardrik.Principal.t() | nil,
          created_at: DateTime.t(),
          secret: String.t() | nil
        }
end
