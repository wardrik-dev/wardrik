defmodule Wardrik.Operations.TokenCreated do
  @moduledoc """
  What `Wardrik.Operations.CreateToken` made: the token, as the host keeps it,
  which only exists once it is made.
  """

  @enforce_keys [:token]
  defstruct [:token]

  @type t() :: %__MODULE__{token: Wardrik.Tokens.Token.t()}

  defimpl Wardrik.Effect do
    def preview(%{token: token}), do: %{"token" => Wardrik.Resource.token(token)}

    def audit(%{token: token}),
      do: [{:token_created, token.id, token.name, token.grant, token.principal}]
  end
end
