defmodule WardrikCore.Keys.Request do
  @moduledoc """
  What a `WardrikCore.Keys` module is asked for: the key `name`, for `principal`.

      %WardrikCore.Keys.Request{name: "BRAVE_API_KEY", principal: %WardrikCore.Principal{id: "acme"}}

  `principal` is the agent's, or `nil` if it has none.
  """

  @enforce_keys [:name, :principal]
  defstruct [:name, :principal]

  @type t() :: %__MODULE__{name: String.t(), principal: WardrikCore.Principal.t() | nil}
end
