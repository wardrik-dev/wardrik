defmodule WardrikDaemon.Tokens.Token do
  @moduledoc """
  A token, without its secret. See `WardrikDaemon.Tokens`.

      %WardrikDaemon.Tokens.Token{
        id: "mzxw6ytboi",
        name: "ana's laptop",
        subject: "user:payments/@ana",
        groups: ["payments-eng"],
        expires: ~U[2027-01-01 00:00:00Z]
      }
  """

  @enforce_keys [:id, :name, :subject, :expires]
  defstruct [:id, :name, :subject, :expires, groups: []]

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          subject: String.t(),
          groups: [String.t()],
          expires: DateTime.t()
        }
end
