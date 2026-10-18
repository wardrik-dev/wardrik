defmodule WardrikHTTP.TokenTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Role
  alias WardrikHTTP.Token

  @jon Wardrik.Principal.new(:user, "jon")

  defp token(roles, opts \\ []) do
    struct!(
      %Wardrik.Token{principal: @jon, scope: [Role.bind(roles, Prefix.parse!("acme/"))]},
      opts
    )
  end

  test "a token is found by its secret, and by nothing else" do
    assert {:ok, "wardrik_" <> _rest = secret, kept} =
             Token.create(store(), "ci", token: token([:owner]))

    assert {:ok, ^kept} = Token.verify(store(), secret)
    assert {:ok, ^kept} = Token.get(store(), kept.id)
    assert :error = Token.get(store(), "0123456789ab")
    assert :error = Token.get(store(), "short")
    assert :error = Token.verify(store(), secret <> "x")
    assert :error = Token.verify(store(), "not-a-token")
    assert %Token{name: "ci", token: %Wardrik.Token{principal: @jon}} = kept
    assert byte_size(kept.id) == 12
  end

  test "a token acts for whoever made it, and a request with it comes from its caller" do
    {:ok, secret, _kept} = Token.create(store(), "laptop", token: token([:reader]))

    assert {:ok, read} = Token.verify(store(), secret)

    assert %WardrikHTTP.Caller{token: %Wardrik.Token{principal: @jon}, id: id, ref: {:tokens, id}} =
             Token.caller(read)
  end

  test "the store holds a hash of the secret under its id, never the secret" do
    {:ok, secret, kept} = Token.create(store(), "hashed", token: token([:owner]))

    hash = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
    assert %Token{hash: ^hash} = WardrikStore.get(store(), :tokens, kept.id)
    assert String.starts_with?(hash, kept.id)
    refute secret in WardrikStore.keys(store(), :tokens, "")
  end

  test "keeps the token's statements and policy as they were made" do
    policy = [Wardrik.Hook.new("careful", Wardrik.Test.Tools.Rules, ask: :all)]

    {:ok, secret, kept} =
      Token.create(store(), "careful", token: token([:definer], policy: policy))

    assert {:ok, %Token{token: %Wardrik.Token{policy: ^policy, scope: [statement]}}} =
             Token.verify(store(), secret)

    assert statement == Role.bind([:definer], Prefix.parse!("acme/"))
    assert kept.token.policy == policy
  end

  test "an expired token stops working" do
    past = DateTime.add(DateTime.utc_now(), -1)
    {:ok, secret, _kept} = Token.create(store(), "old", token: token([:reader], expires: past))

    assert :error = Token.verify(store(), secret)
  end

  test "a revoked token stops working, and is listed no more" do
    {:ok, secret, kept} = Token.create(store(), "revoked", token: token([:owner]))

    assert kept in Token.list(store())

    assert {:error, :not_found} = Token.revoke(store(), binary_part(kept.id, 0, 4))
    assert :ok = Token.revoke(store(), kept.id)

    assert :error = Token.verify(store(), secret)
    assert :error = Token.get(store(), kept.id)
    refute kept in Token.list(store())
    assert {:error, :not_found} = Token.revoke(store(), kept.id)
  end
end
