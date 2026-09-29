defmodule WardrikHTTP.TokenTest do
  use ExUnit.Case, async: true

  alias Wardrik.Grant
  alias WardrikHTTP.Token

  test "a token is found by its secret, and by nothing else" do
    assert {:ok, "wardrik_" <> _rest = secret, token} =
             Token.create("ci", "acme/", Grant.actions(), ceiling: [])

    assert {:ok, ^token} = Token.verify(secret)
    assert :error = Token.verify(secret <> "x")
    assert :error = Token.verify("not-a-token")
    assert %Token{name: "ci", grant: %Grant{scope: "acme/"}} = token
    assert byte_size(token.id) == 12
  end

  test "the store holds a hash of the secret under its id, never the secret" do
    {:ok, secret, token} = Token.create("hashed", "acme/", Grant.actions(), ceiling: [])

    hash = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
    assert %Token{hash: ^hash} = Wardrik.Store.get(:tokens, token.id)
    assert String.starts_with?(hash, token.id)
    refute secret in Wardrik.Store.keys(:tokens, "")
  end

  test "create/3 writes a scope as the key prefix it is" do
    for {given, scope} <- [
          {"", ""},
          {"acme", "acme/"},
          {"acme/jon/triage/", "acme/jon/triage"}
        ] do
      assert {:ok, _secret, %Token{grant: %Grant{scope: ^scope}}} =
               Token.create("scoped", given, Grant.actions(), ceiling: [])
    end
  end

  test "a token grants every action, or the ones it was made with" do
    {:ok, _secret, every} = Token.create("every", "acme/", Grant.actions(), ceiling: [])
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

  describe "a token that can define" do
    test "is made with a ceiling, or with none, and never without saying" do
      ceiling = WardrikPolicy.hooks(%WardrikPolicy{name: "ceiling/careful", default: :ask})

      assert {:error, message} = Token.create("unsaid", "acme/")

      assert message ==
               "A token that can define agents is made with a ceiling, or with none, ceiling: []"

      assert {:error, ^message} = Token.create("definer", "acme/", [:define])

      {:ok, secret, token} = Token.create("careful", "acme/", [:define], ceiling: ceiling)
      assert token.grant.ceiling == ceiling
      assert {:ok, %Token{grant: %Grant{ceiling: ^ceiling}}} = Token.verify(secret)

      {:ok, _secret, token} = Token.create("unlimited", "acme/", [:define], ceiling: [])
      assert token.grant.ceiling == []
    end

    test "is the only kind a ceiling is for" do
      ceiling = WardrikPolicy.hooks(%WardrikPolicy{name: "ceiling/careful"})

      assert {:ok, _secret, _token} = Token.create("reader", "acme/", [:read])

      assert Token.create("reader", "acme/", [:read], ceiling: ceiling) ==
               {:error, "A ceiling holds the agents a grant defines, and this one cannot define"}
    end
  end

  test "a token stored before tokens had ceilings reads as one with none" do
    {:ok, secret, token} = Token.create("older", "acme/", Grant.actions(), ceiling: [])
    older = %{token | grant: Map.delete(token.grant, :ceiling)}
    {_token, vsn} = Wardrik.Store.lookup(:tokens, token.id)
    {:ok, _vsn} = Wardrik.Store.put(:tokens, token.id, older, if_vsn: vsn)

    assert {:ok, %Token{grant: %Grant{ceiling: []}}} = Token.verify(secret)
    assert Enum.find(Token.list(), &(&1.id == token.id)).grant.ceiling == []
  end

  test "a revoked token stops working, and is listed no more" do
    {:ok, secret, token} = Token.create("revoked", "acme/", Grant.actions(), ceiling: [])
    assert token in Token.list()

    assert {:error, :not_found} = Token.revoke(binary_part(token.id, 0, 4))
    assert :ok = Token.revoke(token.id)

    assert :error = Token.verify(secret)
    refute token in Token.list()
    assert {:error, :not_found} = Token.revoke(token.id)
  end
end
