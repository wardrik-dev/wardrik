defmodule WardrikCore.Authorization do
  @moduledoc """
  A sign-in a person must finish before a call can run.

  A call waits on one when `WardrikCore.Credentials.fetch/2` has no token yet. Show the person its
  `url`, then resume the turn once they've signed in.
  """

  @enforce_keys [:url, :credential]
  defstruct [:url, :credential, :principal]

  @type t() :: %__MODULE__{
          url: String.t(),
          credential: String.t(),
          principal: WardrikCore.Principal.t() | nil
        }
end
