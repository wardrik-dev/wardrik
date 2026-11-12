defmodule WardrikCore.Keys.Request do
  @moduledoc """
  What a `WardrikCore.Keys` module is asked for: the key `name`, for the agent's `principal`.

      %WardrikCore.Keys.Request{name: "BRAVE_API_KEY", principal: %WardrikCore.Principal{id: "agent:support"}}
  """

  @enforce_keys [:name, :principal]
  defstruct [:name, :principal]

  @type t() :: %__MODULE__{name: String.t(), principal: WardrikCore.Principal.t() | nil}
end
