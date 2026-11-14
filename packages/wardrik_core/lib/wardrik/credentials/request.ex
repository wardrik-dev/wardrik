defmodule Wardrik.Credentials.Request do
  @moduledoc """
  What a `Wardrik.Credentials` module is asked for: the credential `name`, for `principal`.

      %Wardrik.Credentials.Request{name: "github", principal: %Wardrik.Principal{id: "user:maria"}}

  `principal` is `nil` when the turn acts for no one.
  """

  @enforce_keys [:name, :principal]
  defstruct [:name, :principal]

  @type t() :: %__MODULE__{name: String.t(), principal: Wardrik.Principal.t() | nil}
end
