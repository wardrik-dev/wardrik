defmodule WardrikHTTP.TokensTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.AgentID.Prefix
  alias WardrikHTTP.Token
  alias WardrikHTTP.Tokens

  defp tokens, do: %Tokens{store: Wardrik.Test.store()}

  test "makes, lists and revokes the API's tokens, as Wardrik.Tokens asks" do
    token = %Wardrik.Token{
      principal: Wardrik.Principal.new(:user, "jon"),
      scope: [Wardrik.Role.bind([:reader], Prefix.parse!("acme/"))]
    }

    assert {:ok, %Wardrik.Tokens.Entry{id: id, name: "ci", token: ^token, secret: secret}} =
             Tokens.create(tokens(), "ci", token: token)

    assert {:ok, %Token{id: ^id}} = Token.verify(store(), secret)

    assert [%Wardrik.Tokens.Entry{secret: nil, token: ^token}] =
             for(t <- Tokens.list(tokens()), t.id == id, do: t)

    assert :ok = Tokens.revoke(tokens(), id)
    assert {:error, :not_found} = Tokens.revoke(tokens(), "not-a-token")
    assert :error = Token.verify(store(), secret)
  end
end
