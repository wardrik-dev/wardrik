defmodule WardrikHTTP.TokenTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Grant
  alias WardrikHTTP.Token

  test "a token is found by its secret, and by nothing else" do
    assert {:ok, "wardrik_" <> _rest = secret, token} =
             Token.create(store(), "ci",
               scope: Prefix.parse!("acme/"),
               can: Grant.actions(),
               ceiling: []
             )

    assert {:ok, ^token} = Token.verify(store(), secret)
    assert {:ok, ^token} = Token.get(store(), token.id)
    assert :error = Token.get(store(), "0123456789ab")
    assert :error = Token.get(store(), "short")
    assert :error = Token.verify(store(), secret <> "x")
    assert :error = Token.verify(store(), "not-a-token")
    assert %Token{name: "ci", grant: %Grant{scope: scope}} = token
    assert to_string(scope) == "acme/"
    assert byte_size(token.id) == 12
  end

  test "a token acts for itself, or for the principal it was made for" do
    {:ok, _secret, ci} = Token.create(store(), "ci", scope: Prefix.parse!("acme/"), can: [:read])
    assert Wardrik.Principal.type(Token.principal(ci)) == :token
    assert Wardrik.Principal.id(Token.principal(ci)) == ci.id

    jon = Wardrik.Principal.new(:user, "jon")

    {:ok, secret, for_jon} =
      Token.create(store(), "laptop", scope: Prefix.parse!("acme/"), can: [:read], for: jon)

    assert Token.principal(for_jon) == jon
    assert {:ok, read} = Token.verify(store(), secret)
    assert %WardrikHTTP.Caller{principal: ^jon, id: id, ref: {:tokens, id}} = Token.caller(read)
  end

  test "the store holds a hash of the secret under its id, never the secret" do
    {:ok, secret, token} =
      Token.create(store(), "hashed",
        scope: Prefix.parse!("acme/"),
        can: Grant.actions(),
        ceiling: []
      )

    hash = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
    assert %Token{hash: ^hash} = WardrikStore.get(store(), :tokens, token.id)
    assert String.starts_with?(hash, token.id)
    refute secret in WardrikStore.keys(store(), :tokens, "")
  end

  test "a token grants every action, or the ones it was made with" do
    {:ok, _secret, every} =
      Token.create(store(), "every",
        scope: Prefix.parse!("acme/"),
        can: Grant.actions(),
        ceiling: []
      )

    assert every.grant.can == Grant.actions()

    {:ok, secret, watcher} =
      Token.create(store(), "watcher", scope: Prefix.parse!("acme/"), can: ["read"])

    assert watcher.grant.can == [:read]
    assert {:ok, %Token{grant: %Grant{can: [:read]}}} = Token.verify(store(), secret)

    assert {:error, message} =
             Token.create(store(), "wrong", scope: Prefix.parse!("acme/"), can: ["read", "write"])

    assert message =~ ~s("write" is not an action)
  end

  describe "a token that can define" do
    test "is made with a ceiling, or with none, and never without saying" do
      ceiling = [Wardrik.Hook.new("ceiling/careful", Wardrik.Test.Tools.Rules, ask: :all)]

      assert {:error, message} = Token.create(store(), "unsaid", scope: Prefix.parse!("acme/"))

      assert message ==
               "A token that can define agents is made with a ceiling, or with none, ceiling: []"

      assert {:error, ^message} =
               Token.create(store(), "definer", scope: Prefix.parse!("acme/"), can: [:define])

      {:ok, secret, token} =
        Token.create(store(), "careful",
          scope: Prefix.parse!("acme/"),
          can: [:define],
          ceiling: ceiling
        )

      assert token.grant.ceiling == ceiling
      assert {:ok, %Token{grant: %Grant{ceiling: ^ceiling}}} = Token.verify(store(), secret)

      {:ok, _secret, token} =
        Token.create(store(), "unlimited",
          scope: Prefix.parse!("acme/"),
          can: [:define],
          ceiling: []
        )

      assert token.grant.ceiling == []
    end

    test "is the only kind a ceiling is for" do
      ceiling = [Wardrik.Hook.new("ceiling/careful", Wardrik.Test.Tools.Rules, ask: :all)]

      assert {:ok, _secret, _token} =
               Token.create(store(), "reader", scope: Prefix.parse!("acme/"), can: [:read])

      assert Token.create(store(), "reader",
               scope: Prefix.parse!("acme/"),
               can: [:read],
               ceiling: ceiling
             ) ==
               {:error, "A ceiling holds the agents a grant defines, and this one cannot define"}
    end
  end

  test "a token stored before tokens had ceilings reads as one with none" do
    {:ok, secret, token} =
      Token.create(store(), "older",
        scope: Prefix.parse!("acme/"),
        can: Grant.actions(),
        ceiling: []
      )

    older = %{token | grant: Map.delete(token.grant, :ceiling)}
    {_token, vsn} = WardrikStore.lookup(store(), :tokens, token.id)
    {:ok, _vsn} = WardrikStore.put(store(), :tokens, token.id, older, if_vsn: vsn)

    assert {:ok, %Token{grant: %Grant{ceiling: []}}} = Token.verify(store(), secret)
    assert Enum.find(Token.list(store()), &(&1.id == token.id)).grant.ceiling == []
  end

  test "a revoked token stops working, and is listed no more" do
    {:ok, secret, token} =
      Token.create(store(), "revoked",
        scope: Prefix.parse!("acme/"),
        can: Grant.actions(),
        ceiling: []
      )

    assert token in Token.list(store())

    assert {:error, :not_found} = Token.revoke(store(), binary_part(token.id, 0, 4))
    assert :ok = Token.revoke(store(), token.id)

    assert :error = Token.verify(store(), secret)
    assert :error = Token.get(store(), token.id)
    refute token in Token.list(store())
    assert {:error, :not_found} = Token.revoke(store(), token.id)
  end
end
