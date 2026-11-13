defmodule WardrikDaemon.TokensTest do
  use ExUnit.Case, async: true

  alias Wardrik.HTTP.Authenticator.Request
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Authenticator
  alias WardrikDaemon.Tokens
  alias WardrikDaemon.Tokens.Token

  setup context do
    store = Wardrik.Store.ETS.new(name: :"tokens #{context.test}")
    start_supervised!({Wardrik.Store, store})
    %{store: Wardrik.Store.scope(store, "wardrik_daemon", format: Wardrik.Store.Format.Term)}
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
    {:ok, %{secret: secret}} = create(store, "user:payments/@ana", groups: ["payments-eng"])
    assert {:ok, scope} = authenticate(store, bearer(secret))

    assert %{
             principal: %{id: "payments/@ana", attributes: %{groups: ["payments-eng"]}},
             actor: nil
           } = scope

    {:ok, helper} =
      AgentRecords.create(store, owner: "payments/@ana", name: "helper", source: :api)

    {:ok, %{secret: secret}} = create(store, "agent:" <> helper.id)
    assert {:ok, scope} = authenticate(store, bearer(secret))
    assert %{principal: %{id: "payments/@ana"}, actor: {:agent, id}} = scope
    assert id == helper.id
  end

  test "refuses a missing header, a wrong secret, and a revoked or expired token", %{store: store} do
    {:ok, %{token: token, secret: secret}} = create(store, "user:payments/@ana")

    {:ok, %{secret: expired}} =
      create(store, "user:payments/@ana", expires: DateTime.add(DateTime.utc_now(), -1, :second))

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
    {:ok, %{token: token, secret: secret}} = create(store, "user:payments/@ana")
    assert "wdk_" <> _rest = secret

    kept = Wardrik.Store.entries(store, "")
    refute inspect(kept, limit: :infinity, printable_limit: :infinity) =~ secret
    refute inspect(Tokens.list(store)) =~ secret
    assert [%Token{id: id, subject: "user:payments/@ana"}] = Tokens.list(store)
    assert id == token.id
  end

  test "makes tokens only for people in orgs, the admin and agents", %{store: store} do
    for subject <- ["user:payments/@ana", "user:admin", "agent:agt_1"] do
      assert {:ok, %{token: %Token{subject: ^subject}}} = create(store, subject)
    end

    for subject <- ["group:eng", "user:", "user:deployment", "ana", "agent:"] do
      assert {:error, %NimbleOptions.ValidationError{}} = create(store, subject)
    end
  end

  # An org's own ID would own the org's agents and secrets, so no token acts as one.
  test "refuses a user that isn't a person in an org", %{store: store} do
    for subject <- [
          "user:ana",
          "user:payments",
          "user:payments/ana",
          "user:payments/@",
          "user:payments/@ana/x",
          "user:@ana",
          "user:payments/@*",
          "user:../@ana"
        ] do
      assert {:error, %NimbleOptions.ValidationError{message: message}} = create(store, subject)
      assert message =~ "expected a user, as user:acme/@ana"
    end
  end
end
