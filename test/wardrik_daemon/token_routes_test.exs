defmodule WardrikDaemon.TokenRoutesTest do
  use ExUnit.Case, async: false

  import WardrikDaemon.Test

  alias WardrikDaemon.Client
  alias WardrikDaemon.Tokens

  setup context do
    context = dirs(context)
    port = free_port()

    write(context, "config.yaml", """
    org: payments
    orgs: {growth: {}}
    http: {port: #{port}}
    defaults: {model: #{model()}}
    roles:
      issuer: {rules: [{verbs: ["*"], kinds: [token]}]}
      minter: {rules: [{verbs: [create], kinds: [token], names: ["user:bot"]}]}
      reader: {rules: [{verbs: [read], kinds: [secret]}]}
    bindings:
      - {org: "*", role: issuer, subjects: [user:ops]}
      - {org: "*", role: minter, subjects: [user:minty]}
      - {org: payments, role: operator, subjects: [user:ana, agent:payments/helper]}
      - {org: payments, role: reader, subjects: [group:payments-eng]}
    """)

    context = start_daemon(context)
    Map.put(context, :url, "http://127.0.0.1:#{port}")
  end

  defp client(context, subject) do
    {:ok, %{secret: secret}} =
      Tokens.create(context.daemon_store,
        name: "test",
        subject: subject,
        expires: DateTime.add(DateTime.utc_now(), 1, :hour)
      )

    %Client{url: context.url, secret: secret}
  end

  defp create(client, subject, fields \\ %{}),
    do:
      Client.run(
        client,
        "tokens.create",
        Map.merge(%{"name" => "made", "subject" => subject}, fields)
      )

  test "only a binding on the token kind creates, lists or revokes tokens", context do
    ops = client(context, "user:ops")
    {:ok, %{"id" => id}} = create(ops, "user:bo")

    for subject <- ["user:ana", "agent:payments/helper", "user:bo"] do
      someone = client(context, subject)
      assert {:error, "not_found", _message} = create(someone, "user:bo")
      assert {:error, "not_found", _message} = Client.run(someone, "tokens.list", %{})
      assert {:error, "not_found", _message} = Client.run(someone, "tokens.revoke", %{"id" => id})
    end

    assert {:ok, %{"tokens" => tokens}} = Client.run(ops, "tokens.list", %{})
    assert id in Enum.map(tokens, & &1["id"])
  end

  test "no one but the admin makes a token for the admin, whatever their token bindings",
       context do
    for subject <- ["user:ops", "user:minty", "user:ana", "agent:payments/helper"] do
      assert {:error, "forbidden", _message} = create(client(context, subject), "user:admin")
    end

    assert {:ok, %{"subject" => "user:admin"}} =
             create(client(context, "user:admin"), "user:admin")

    assert {:ok, %{"subject" => "user:bo"}} = create(client(context, "user:ops"), "user:bo")

    minty = client(context, "user:minty")
    assert {:ok, %{"subject" => "user:bot"}} = create(minty, "user:bot")
    assert {:error, "forbidden", _message} = create(minty, "user:bo")
    assert {:error, "forbidden", _message} = Client.run(minty, "tokens.list", %{})
  end

  test "a token made acts as its subject and groups alone", context do
    ops = client(context, "user:ops")

    assert {:ok, %{"secret" => secret, "groups" => ["payments-eng"], "expires" => expires}} =
             create(ops, "user:bo", %{"groups" => ["payments-eng"], "expires_in" => 3600})

    {:ok, expires, 0} = DateTime.from_iso8601(expires)
    assert DateTime.diff(expires, DateTime.utc_now()) in 3590..3600

    bo = %Client{url: context.url, secret: secret}
    assert {:ok, %{"secrets" => []}} = Client.run(bo, "secrets.list", %{"owner" => "payments"})

    assert {:error, "forbidden", _message} =
             Client.run(bo, "secrets.put", %{
               "owner" => "payments",
               "name" => "X",
               "value" => "v",
               "purpose" => "api_key"
             })

    assert {:error, "not_found", _message} =
             Client.run(bo, "secrets.list", %{"owner" => "growth"})

    assert {:error, "not_found", _message} = Client.run(bo, "tokens.list", %{})
  end

  test "answers a secret once, and never lists or keeps it", context do
    ops = client(context, "user:ops")
    {:ok, %{"id" => id, "secret" => secret}} = create(ops, "user:bo")
    assert "wdk_" <> _rest = secret

    assert {:ok, answer} = Client.run(ops, "tokens.list", %{})
    refute JSON.encode!(answer) =~ secret
    refute JSON.encode!(answer) =~ "wdk_"
    refute :erlang.term_to_binary(WardrikStore.entries(context.daemon_store, "")) =~ secret

    bo = %Client{url: context.url, secret: secret}

    assert {:error, "not_found", _message} =
             Client.run(bo, "secrets.list", %{"owner" => "payments"})

    assert {:ok, nil} = Client.run(ops, "tokens.revoke", %{"id" => id})

    assert {:error, "unauthorized", _message} =
             Client.run(bo, "secrets.list", %{"owner" => "payments"})

    assert {:ok, %{"tokens" => tokens}} = Client.run(ops, "tokens.list", %{})
    refute id in Enum.map(tokens, & &1["id"])
  end

  test "refuses a token that doesn't read", context do
    ops = client(context, "user:ops")

    for {subject, fields} <- [
          {"group:eng", %{}},
          {"user:deployment", %{}},
          {"ana", %{}},
          {"user:ana", %{"expires_in" => 0}},
          {"user:ana", %{"secret" => "wdk_mine"}},
          {"user:ana", %{"name" => ""}}
        ] do
      assert {:error, "invalid_request", _message} = create(ops, subject, fields)
    end
  end
end
