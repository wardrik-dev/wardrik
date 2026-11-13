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
      minter: {rules: [{verbs: [create], kinds: [token], names: ["user:payments/@bot"]}]}
      reader: {rules: [{verbs: [read], kinds: [secret]}]}
      tokens_maker: {rules: [{verbs: [create, read], kinds: [token]}]}
      tokens_remover: {rules: [{verbs: [delete], kinds: [token]}]}
    bindings:
      - {org: "*", role: issuer, subjects: [user:payments/@ops]}
      - {org: "*", role: minter, subjects: [user:payments/@minty]}
      - {org: "*", role: tokens_maker, subjects: [user:payments/@mae]}
      - {org: "*", role: tokens_remover, subjects: [user:payments/@del]}
      - {org: payments, role: operator, subjects: [user:payments/@ana, agent:helper]}
      - {org: payments, role: reader, subjects: [group:payments-eng]}
    """)

    context = start_daemon(context)
    helper = "agent:" <> agent(context, "payments", "helper")
    Map.merge(context, %{url: "http://127.0.0.1:#{port}", helper: helper})
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
    ops = client(context, "user:payments/@ops")
    {:ok, %{"id" => id}} = create(ops, "user:payments/@bo")

    for subject <- ["user:payments/@ana", context.helper, "user:payments/@bo"] do
      someone = client(context, subject)
      assert {:error, "not_found", _message} = create(someone, "user:payments/@bo")
      assert {:error, "not_found", _message} = Client.run(someone, "tokens.list", %{})
      assert {:error, "not_found", _message} = Client.run(someone, "tokens.revoke", %{"id" => id})
    end

    assert {:ok, %{"tokens" => tokens}} = Client.run(ops, "tokens.list", %{})
    assert id in Enum.map(tokens, & &1["id"])
  end

  test "no one but the admin makes a token for the admin, whatever their token bindings",
       context do
    for subject <- [
          "user:payments/@ops",
          "user:payments/@minty",
          "user:payments/@ana",
          context.helper
        ] do
      assert {:error, "forbidden", _message} = create(client(context, subject), "user:admin")
    end

    assert {:ok, %{"subject" => "user:admin"}} =
             create(client(context, "user:admin"), "user:admin")

    assert {:ok, %{"subject" => "user:payments/@bo"}} =
             create(client(context, "user:payments/@ops"), "user:payments/@bo")

    minty = client(context, "user:payments/@minty")
    assert {:ok, %{"subject" => "user:payments/@bot"}} = create(minty, "user:payments/@bot")
    assert {:error, "forbidden", _message} = create(minty, "user:payments/@bo")
    assert {:error, "forbidden", _message} = Client.run(minty, "tokens.list", %{})
  end

  test "a token made acts as its subject and groups alone", context do
    ops = client(context, "user:payments/@ops")

    assert {:ok, %{"secret" => secret, "groups" => ["payments-eng"], "expires" => expires}} =
             create(ops, "user:payments/@bo", %{
               "groups" => ["payments-eng"],
               "expires_in" => 3600
             })

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
    ops = client(context, "user:payments/@ops")
    {:ok, %{"id" => id, "secret" => secret}} = create(ops, "user:payments/@bo")
    assert "wdk_" <> _rest = secret

    assert {:ok, answer} = Client.run(ops, "tokens.list", %{})
    refute JSON.encode!(answer) =~ secret
    refute JSON.encode!(answer) =~ "wdk_"
    entries = Wardrik.Store.entries(context.daemon_store, "")
    refute :erlang.term_to_binary(entries) =~ secret

    bo = %Client{url: context.url, secret: secret}

    assert {:error, "not_found", _message} =
             Client.run(bo, "secrets.list", %{"owner" => "payments"})

    assert {:ok, nil} = Client.run(ops, "tokens.revoke", %{"id" => id})

    assert {:error, "unauthorized", _message} =
             Client.run(bo, "secrets.list", %{"owner" => "payments"})

    assert {:ok, %{"tokens" => tokens}} = Client.run(ops, "tokens.list", %{})
    refute id in Enum.map(tokens, & &1["id"])
  end

  test "a token made for a person owns their agents, with no binding", context do
    mine = agent(context, "growth/@ana", "notes")

    {:ok, %{"secret" => secret}} =
      create(client(context, "user:payments/@ops"), "user:growth/@ana")

    ana = %Client{url: context.url, secret: secret}

    assert {:ok, %{"definition" => _definition}} =
             Client.run(ana, "agent.definition", %{"agent" => mine})

    assert {:ok, nil} = Client.run(ana, "agent.forget", %{"agent" => mine})
    "agent:" <> helper = context.helper

    assert {:error, "not_found", _message} =
             Client.run(ana, "agent.definition", %{"agent" => helper})
  end

  # A token for an org would act as the org, owning its agents and secrets.
  test "refuses a user that isn't a person in an org", context do
    ops = client(context, "user:payments/@ops")

    for subject <- [
          "user:growth",
          "user:payments",
          "user:ana",
          "user:growth/@",
          "user:growth/ana"
        ] do
      assert {:error, "invalid_request", message} = create(ops, subject)
      assert message =~ "expected a user, as user:acme/@ana"
    end
  end

  test "refuses a token that doesn't read", context do
    ops = client(context, "user:payments/@ops")

    for {subject, fields} <- [
          {"group:eng", %{}},
          {"user:deployment", %{}},
          {"ana", %{}},
          {"user:payments/@ana", %{"expires_in" => 0}},
          {"user:payments/@ana", %{"secret" => "wdk_mine"}},
          {"user:payments/@ana", %{"name" => ""}}
        ] do
      assert {:error, "invalid_request", _message} = create(ops, subject, fields)
    end
  end

  # Revoking is its own verb, as Kubernetes' delete: creating doesn't allow it.
  test "revoking a token needs delete, not create", context do
    maker = client(context, "user:payments/@mae")
    remover = client(context, "user:payments/@del")

    assert {:ok, %{"id" => id}} = create(maker, "user:payments/@bo")
    assert {:error, "forbidden", _message} = Client.run(maker, "tokens.revoke", %{"id" => id})
    assert {:error, "forbidden", _message} = create(remover, "user:payments/@bo")
    assert {:ok, nil} = Client.run(remover, "tokens.revoke", %{"id" => id})
    assert {:ok, %{"tokens" => tokens}} = Client.run(maker, "tokens.list", %{})
    refute id in Enum.map(tokens, & &1["id"])
  end
end
