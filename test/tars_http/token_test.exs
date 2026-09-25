defmodule TarsHTTP.TokenTest do
  use ExUnit.Case, async: true

  alias TarsHTTP.Token

  test "a token is found by its secret, and by nothing else" do
    assert {:ok, "tars_" <> _rest = secret, token} = Token.create("ci", "acme/")

    assert {:ok, ^token} = Token.verify(secret)
    assert :error = Token.verify(secret <> "x")
    assert :error = Token.verify("not-a-token")
    assert %Token{name: "ci", scope: "acme/"} = token
    assert byte_size(token.id) == 12
  end

  test "the store holds a hash of the secret, never the secret" do
    {:ok, secret, token} = Token.create("hashed", "acme/")

    [hash] = Tars.Store.keys(:tokens, token.id)
    assert hash == :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
    refute Enum.any?(Tars.Store.keys(:tokens, ""), &(&1 == secret))
  end

  test "a token reaches the agents under its scope, and an empty scope reaches every agent" do
    token = %Token{id: "3f9a61c0d4e2", name: "ci", scope: "acme/", created_at: DateTime.utc_now()}

    assert Token.covers?(token, "acme/jon/triage")
    refute Token.covers?(token, "globex/_/triage")
    assert Token.covers?(%{token | scope: ""}, "globex/_/triage")
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
