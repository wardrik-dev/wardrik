defmodule TarsHTTP.TokenTest do
  use ExUnit.Case, async: true

  alias Tars.Grant
  alias TarsHTTP.Token

  test "a token is found by its secret, and by nothing else" do
    assert {:ok, "tars_" <> _rest = secret, token} = Token.create("ci", "acme/")

    assert {:ok, ^token} = Token.verify(secret)
    assert :error = Token.verify(secret <> "x")
    assert :error = Token.verify("not-a-token")
    assert %Token{name: "ci", grant: %Grant{scope: "acme/"}} = token
    assert byte_size(token.id) == 12
  end

  test "the store holds a hash of the secret under its id, never the secret" do
    {:ok, secret, token} = Token.create("hashed", "acme/")

    hash = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
    assert %Token{hash: ^hash} = Tars.Store.get(:tokens, token.id)
    assert String.starts_with?(hash, token.id)
    refute secret in Tars.Store.keys(:tokens, "")
  end

  test "create/3 writes a scope as the key prefix it is" do
    for {given, scope} <- [
          {"", ""},
          {"acme", "acme/"},
          {"acme/jon/triage/", "acme/jon/triage"}
        ] do
      assert {:ok, _secret, %Token{grant: %Grant{scope: ^scope}}} = Token.create("scoped", given)
    end
  end

  test "a token grants every action, or the ones it was made with" do
    {:ok, _secret, every} = Token.create("every", "acme/")
    assert every.grant.can == Grant.actions()

    {:ok, secret, watcher} = Token.create("watcher", "acme/", ["read"])
    assert watcher.grant.can == [:read]
    assert {:ok, %Token{grant: %Grant{can: [:read]}}} = Token.verify(secret)

    assert {:error, message} = Token.create("wrong", "acme/", ["read", "write"])
    assert message =~ ~s("write" is not an action)
  end

  test "create/3 refuses a scope that is not a key prefix" do
    for scope <- ["/", "/acme", "acme//jon", "acme/jon/triage/more"] do
      assert {:error, message} = Token.create("unscoped", scope)

      assert message ==
               "#{inspect(scope)} is not a scope; a scope is org/, org/user/ or a key, org/user/name"
    end
  end

  test "a revoked token stops working, and is listed no more" do
    {:ok, secret, token} = Token.create("revoked", "acme/")
    assert token in Token.list()

    assert {:error, :not_found} = Token.revoke(binary_part(token.id, 0, 4))
    assert :ok = Token.revoke(token.id)

    assert :error = Token.verify(secret)
    refute token in Token.list()
    assert {:error, :not_found} = Token.revoke(token.id)
  end
end
