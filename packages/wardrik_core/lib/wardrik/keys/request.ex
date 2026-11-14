defmodule Wardrik.Keys.Request do
  @moduledoc """
  What a `Wardrik.Keys` module is asked for: the key `name`, for the agent's `principal`.

      %Wardrik.Keys.Request{name: "BRAVE_API_KEY", principal: %Wardrik.Principal{id: "agent:support"}}
  """

  @enforce_keys [:name, :principal]
  defstruct [:name, :principal]

  @type t() :: %__MODULE__{name: String.t(), principal: Wardrik.Principal.t() | nil}
end
