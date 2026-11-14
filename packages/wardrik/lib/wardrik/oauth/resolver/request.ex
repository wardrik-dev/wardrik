defmodule Wardrik.OAuth.Resolver.Request do
  @moduledoc """
  What `c:Wardrik.OAuth.Resolver.provider/2` resolves: the provider `principal` signs in with as
  `name`.

      %Wardrik.OAuth.Resolver.Request{name: "github", principal: %Wardrik.Principal{id: "user_42"}}
  """

  @enforce_keys [:name, :principal]
  defstruct [:name, :principal]

  @type t() :: %__MODULE__{name: String.t(), principal: Wardrik.Principal.t()}
end
