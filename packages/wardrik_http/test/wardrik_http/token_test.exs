defmodule WardrikHTTP.TokenTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Grant
  alias WardrikHTTP.Token

  test "a token is found by its secret, and by nothing else" do
    assert {:ok, "wardrik_" <> _rest = secret, token} =
             Token.create("ci", Prefix.parse!("acme/"), Grant.actions(), ceiling: [])

    assert {:ok, ^token} = Token.verify(secret)
    assert :error = Token.verify(secret <> "x")
    assert :error = Token.verify("not-a-token")
    assert %Token{name: "ci", grant: %Grant{scope: scope}} = token
    assert to_string(scope) == "acme/"
    assert byte_size(token.id) == 12
  end

  test "the store holds a hash of the secret under its id, never the secret" do
    {:ok, secret, token} =
      Token.create("hashed", Prefix.parse!("acme/"), Grant.actions(), ceiling: [])

    hash = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
    assert %Token{hash: ^hash} = WardrikStore.get(:tokens, token.id)
    assert String.starts_with?(hash, token.id)
    refute secret in WardrikStore.keys(:tokens, "")
  end

  test "a token grants every action, or the ones it was made with" do
    {:ok, _secret, every} =
      Token.create("every", Prefix.parse!("acme/"), Grant.actions(), ceiling: [])

    assert every.grant.can == Grant.actions()

    {:ok, secret, watcher} =
      Token.create("watcher", Prefix.parse!("acme/"), ["read"])

    assert watcher.grant.can == [:read]
    assert {:ok, %Token{grant: %Grant{can: [:read]}}} = Token.verify(secret)

    assert {:error, message} =
             Token.create("wrong", Prefix.parse!("acme/"), ["read", "write"])

    assert message =~ ~s("write" is not an action)
  end

  describe "a token that can define" do
    test "is made with a ceiling, or with none, and never without saying" do
      ceiling = [Wardrik.Hook.new("ceiling/careful", Wardrik.Test.Tools.Rules, ask: :all)]

      assert {:error, message} = Token.create("unsaid", Prefix.parse!("acme/"))

      assert message ==
               "A token that can define agents is made with a ceiling, or with none, ceiling: []"

      assert {:error, ^message} =
               Token.create("definer", Prefix.parse!("acme/"), [:define])

      {:ok, secret, token} =
        Token.create("careful", Prefix.parse!("acme/"), [:define], ceiling: ceiling)

      assert token.grant.ceiling == ceiling
      assert {:ok, %Token{grant: %Grant{ceiling: ^ceiling}}} = Token.verify(secret)

      {:ok, _secret, token} =
        Token.create("unlimited", Prefix.parse!("acme/"), [:define], ceiling: [])

      assert token.grant.ceiling == []
    end

    test "is the only kind a ceiling is for" do
      ceiling = [Wardrik.Hook.new("ceiling/careful", Wardrik.Test.Tools.Rules, ask: :all)]

      assert {:ok, _secret, _token} =
               Token.create("reader", Prefix.parse!("acme/"), [:read])

      assert Token.create("reader", Prefix.parse!("acme/"), [:read], ceiling: ceiling) ==
               {:error, "A ceiling holds the agents a grant defines, and this one cannot define"}
    end
  end

  test "a token stored before tokens had ceilings reads as one with none" do
    {:ok, secret, token} =
      Token.create("older", Prefix.parse!("acme/"), Grant.actions(), ceiling: [])

    older = %{token | grant: Map.delete(token.grant, :ceiling)}
    {_token, vsn} = WardrikStore.lookup(:tokens, token.id)
    {:ok, _vsn} = WardrikStore.put(:tokens, token.id, older, if_vsn: vsn)

    assert {:ok, %Token{grant: %Grant{ceiling: []}}} = Token.verify(secret)
    assert Enum.find(Token.list(), &(&1.id == token.id)).grant.ceiling == []
  end

  test "a revoked token stops working, and is listed no more" do
    {:ok, secret, token} =
      Token.create("revoked", Prefix.parse!("acme/"), Grant.actions(), ceiling: [])

    assert token in Token.list()

    assert {:error, :not_found} = Token.revoke(binary_part(token.id, 0, 4))
    assert :ok = Token.revoke(token.id)

    assert :error = Token.verify(secret)
    refute token in Token.list()
    assert {:error, :not_found} = Token.revoke(token.id)
  end
end
