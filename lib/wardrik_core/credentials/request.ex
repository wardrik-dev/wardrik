defmodule WardrikCore.Credentials.Request do
  @moduledoc """
  What a `WardrikCore.Credentials` module is asked for: the credential `name`, for `principal`.

      %WardrikCore.Credentials.Request{name: "github", principal: %WardrikCore.Principal{id: "user:maria"}}

  `principal` is `nil` when the turn acts for no one.
  """

  @enforce_keys [:name, :principal]
  defstruct [:name, :principal]

  @type t() :: %__MODULE__{name: String.t(), principal: WardrikCore.Principal.t() | nil}
end
