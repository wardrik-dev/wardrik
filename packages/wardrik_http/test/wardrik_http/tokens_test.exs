defmodule WardrikHTTP.TokensTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Grant
  alias WardrikHTTP.Token
  alias WardrikHTTP.Tokens

  defp tokens, do: %Tokens{store: Wardrik.Test.store()}

  test "makes, lists and revokes the API's tokens, as Wardrik.Tokens asks" do
    {:ok, grant} = Grant.new(Prefix.parse!("acme/"), [:read])
    jon = Wardrik.Principal.new(:user, "jon")

    assert {:ok, secret, %Token{id: id, name: "ci", principal: ^jon}} =
             Tokens.create(tokens(), "ci", grant: grant, for: jon)

    assert {:ok, %Token{id: ^id}} = Token.verify(store(), secret)
    assert Enum.any?(Tokens.list(tokens()), &(&1.id == id))

    assert :ok = Tokens.revoke(tokens(), id)
    assert {:error, :not_found} = Tokens.revoke(tokens(), "not-a-token")
    assert :error = Token.verify(store(), secret)
  end
end
