defmodule WardrikHTTP.TokensTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Grant
  alias WardrikHTTP.Token
  alias WardrikHTTP.Tokens

  test "makes, lists and revokes the API's tokens, as Wardrik.Tokens asks" do
    {:ok, grant} = Grant.new(Prefix.parse!("acme/"), [:read])
    jon = Wardrik.Principal.new(:user, "jon")

    assert {:ok, secret, %Token{id: id, name: "ci", principal: ^jon}} =
             Tokens.create("ci", grant, jon)

    assert {:ok, %Token{id: ^id}} = Token.verify(secret)
    assert Enum.any?(Tokens.list(), &(&1.id == id))

    assert :ok = Tokens.revoke(id)
    assert {:error, :not_found} = Tokens.revoke("not-a-token")
    assert :error = Token.verify(secret)
  end
end
