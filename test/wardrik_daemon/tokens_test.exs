defmodule WardrikDaemon.TokensTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.Authenticator
  alias WardrikDaemon.Tokens
  alias WardrikDaemon.Tokens.Token
  alias WardrikHTTP.Authenticator.Request

  setup context do
    store = WardrikStore.ETS.new(name: :"tokens #{context.test}")
    start_supervised!({WardrikStore, store})
    %{store: WardrikStore.scope(store, "wardrik_daemon")}
  end

  defp create(store, subject, opts \\ []) do
    Tokens.create(
      store,
      Keyword.merge(
        [name: "laptop", subject: subject, expires: DateTime.add(DateTime.utc_now(), 1, :hour)],
        opts
      )
    )
  end

  defp authenticate(store, headers) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(:get, "/v1/agents"), fn {key, value}, conn ->
        Plug.Conn.put_req_header(conn, key, value)
      end)

    Authenticator.authenticate(%Request{conn: conn, server: Wardrik, wardrik: :tokens}, store)
  end

  defp bearer(secret), do: [{"authorization", "Bearer " <> secret}]

  test "authenticates a user with its groups, and an agent for its owner", %{store: store} do
    {:ok, %{secret: secret}} = create(store, "user:ana", groups: ["payments-eng"])
    assert {:ok, scope} = authenticate(store, bearer(secret))
    assert %{principal: %{id: "ana", attributes: %{groups: ["payments-eng"]}}, actor: nil} = scope

    {:ok, %{secret: secret}} = create(store, "agent:payments/@ana/helper")
    assert {:ok, scope} = authenticate(store, bearer(secret))
    assert %{principal: %{id: "payments/@ana"}, actor: {:agent, "payments/@ana/helper"}} = scope
  end

  test "refuses a missing header, a wrong secret, and a revoked or expired token", %{store: store} do
    {:ok, %{token: token, secret: secret}} = create(store, "user:ana")

    {:ok, %{secret: expired}} =
      create(store, "user:ana", expires: DateTime.add(DateTime.utc_now(), -1, :second))

    {:ok, %{secret: agentless}} = create(store, "agent:nobody")
    "wdk_" <> rest = secret
    [id, _random] = String.split(rest, "_", parts: 2)

    for headers <- [
          [],
          [{"authorization", secret}],
          bearer("wdk_#{id}_wrong"),
          bearer("wdk_none_" <> String.duplicate("a", 43)),
          bearer(expired),
          bearer(agentless)
        ] do
      assert {:error, %Wardrik.Error{type: :unauthorized}} = authenticate(store, headers)
    end

    assert {:ok, _scope} = authenticate(store, bearer(secret))
    assert Tokens.revoke(store, token.id) == :ok
    assert {:error, %Wardrik.Error{type: :unauthorized}} = authenticate(store, bearer(secret))
  end

  test "keeps only a hash of each secret, and never lists one", %{store: store} do
    {:ok, %{token: token, secret: secret}} = create(store, "user:ana")
    assert "wdk_" <> _rest = secret

    kept = WardrikStore.entries(store, "")
    refute inspect(kept, limit: :infinity, printable_limit: :infinity) =~ secret
    refute inspect(Tokens.list(store)) =~ secret
    assert [%Token{id: id, subject: "user:ana"}] = Tokens.list(store)
    assert id == token.id
  end

  test "makes tokens only for users and agents, not the deployment", %{store: store} do
    assert {:ok, _created} = create(store, "user:ana")

    for subject <- ["group:eng", "user:", "user:deployment", "ana"] do
      assert {:error, %NimbleOptions.ValidationError{}} = create(store, subject)
    end
  end
end
