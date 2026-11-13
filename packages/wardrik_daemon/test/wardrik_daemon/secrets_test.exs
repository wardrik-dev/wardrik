defmodule WardrikDaemon.SecretsTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias WardrikCore.Principal
  alias WardrikDaemon.Client
  alias WardrikDaemon.Tokens

  setup :set_mimic_global

  setup context do
    context = dirs(context)
    port = free_port()

    write(context, "config.yaml", """
    org: payments
    orgs: {growth: {}}
    http: {port: #{port}}
    defaults: {model: #{model()}}
    deployment_keys: false
    roles:
      adder: {rules: [{verbs: [put, read], kinds: [secret]}]}
      remover: {rules: [{verbs: [delete, read], kinds: [secret]}]}
      reader: {rules: [{verbs: [read], kinds: [secret]}]}
    bindings:
      - {org: payments, role: operator, subjects: [user:payments/@ana]}
      - {org: payments, role: adder, subjects: [user:payments/@bo]}
      - {org: payments, role: remover, subjects: [user:payments/@dee]}
      - {org: growth, role: reader, subjects: [agent:helper]}
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

  defp put(client, owner, name, purpose \\ "api_key"),
    do:
      Client.run(client, "secrets.put", %{
        "owner" => owner,
        "name" => name,
        "value" => "sk-" <> name,
        "purpose" => purpose
      })

  defp list(client, owner), do: Client.run(client, "secrets.list", %{"owner" => owner})

  defp vault(context), do: context.wardrik |> Wardrik.Instance.fetch!() |> Wardrik.vault()

  test "a token bound in one org reaches no other org's secrets, nor the deployment's", context do
    admin = client(context, "user:admin")
    ana = client(context, "user:payments/@ana")

    for owner <- ["growth", "deployment"], do: {:ok, nil} = put(admin, owner, "THEIRS")

    assert {:ok, nil} = put(ana, "payments", "OURS")
    assert {:ok, %{"secrets" => [%{"name" => "OURS"}]}} = list(ana, "payments")

    for owner <- ["growth", "growth/@cy", "deployment"] do
      assert {:error, "not_found", _message} = list(ana, owner)
      assert {:error, "not_found", _message} = put(ana, owner, "THEIRS")

      assert {:error, "not_found", _message} =
               Client.run(ana, "secrets.delete", %{"owner" => owner, "name" => "THEIRS"})
    end

    assert {:ok, %{"secrets" => [%{"name" => "THEIRS"}]}} = list(admin, "growth")
    assert {:ok, %{"secrets" => [%{"name" => "THEIRS"}]}} = list(admin, "deployment")
  end

  test "a person manages their own secrets, and no one else's in their org", context do
    cy = client(context, "user:growth/@cy")

    assert {:ok, nil} = put(cy, "growth/@cy", "MINE")
    assert {:ok, %{"secrets" => [%{"name" => "MINE"}]}} = list(cy, "growth/@cy")

    assert {:ok, nil} =
             Client.run(cy, "secrets.delete", %{"owner" => "growth/@cy", "name" => "MINE"})

    assert {:ok, %{"secrets" => []}} = list(cy, "growth/@cy")

    for owner <- ["growth/@dee", "growth"] do
      assert {:error, "not_found", _message} = list(cy, owner)
      assert {:error, "not_found", _message} = put(cy, owner, "MINE")
    end

    helper = client(context, "agent:" <> agent(context, "growth", "helper"))
    assert {:ok, %{"secrets" => []}} = list(helper, "growth")
    assert {:error, "forbidden", _message} = put(helper, "growth", "BOUND")
  end

  test "lists names and purposes, never a value, and seals each for its purpose alone", context do
    admin = client(context, "user:admin")
    {:ok, nil} = put(admin, "growth", "MCP_TOKEN", "header")
    {:ok, nil} = put(admin, "growth", "ANTHROPIC_API_KEY")

    assert {:ok, %{"secrets" => secrets} = answer} = list(admin, "growth")

    assert secrets == [
             %{"name" => "ANTHROPIC_API_KEY", "purpose" => "api_key"},
             %{"name" => "MCP_TOKEN", "purpose" => "header"}
           ]

    refute JSON.encode!(answer) =~ "sk-"

    key = fn name ->
      WardrikDaemon.Keys.fetch(
        %WardrikCore.Keys.Request{name: name, principal: %Principal{id: "growth/@cy"}},
        wardrik: context.wardrik,
        deployment: true
      )
    end

    assert key.("ANTHROPIC_API_KEY") == {:ok, "sk-ANTHROPIC_API_KEY"}
    assert key.("MCP_TOKEN") == {:error, :not_found}

    assert {:ok, "sk-MCP_TOKEN"} =
             Wardrik.Vault.fetch(vault(context), %Principal{id: "growth"}, "MCP_TOKEN",
               kind: :header
             )
  end

  test "reconnects the owner's servers whose headers read a secret it seals or removes",
       context do
    test = self()

    stub(Wardrik.MCP, :reconnect, fn _mcp, changed ->
      send(test, {:reconnect, changed})
      :ok
    end)

    admin = client(context, "user:admin")
    {:ok, nil} = put(admin, "growth", "MCP_TOKEN", "header")
    assert_receive {:reconnect, [owner: "growth", secret: "MCP_TOKEN"]}

    {:ok, nil} =
      Client.run(admin, "secrets.delete", %{"owner" => "growth", "name" => "MCP_TOKEN"})

    assert_receive {:reconnect, [owner: "growth", secret: "MCP_TOKEN"]}

    assert {:ok, %{"events" => events}} = Wardrik.run(context.admin, "audit.list", %{})

    assert for(%{"subject" => "secrets/MCP_TOKEN"} = event <- events, do: event["type"]) ==
             ["wardrik.secret.stored", "wardrik.secret.removed"]
  end

  test "refuses an owner it doesn't name, and a secret it can't seal", context do
    admin = client(context, "user:admin")

    assert {:error, "not_found", "There's no secrets of growth/triage."} =
             list(admin, "growth/triage")

    assert {:error, "not_found", "There's no secrets of globex."} = put(admin, "globex", "KEY")

    for input <- [
          %{"value" => "", "purpose" => "api_key"},
          %{"value" => "v", "purpose" => "grant"}
        ] do
      assert {:error, "invalid_request", _message} =
               Client.run(
                 admin,
                 "secrets.put",
                 Map.merge(input, %{"owner" => "growth", "name" => "X"})
               )
    end

    assert {:error, "invalid_request", _message} =
             Client.run(admin, "secrets.put", %{"owner" => "growth", "name" => "X"})
  end

  # Removing is its own verb, as Kubernetes' delete: putting doesn't allow it.
  test "removing a secret needs delete, not put", context do
    putter = client(context, "user:payments/@bo")
    remover = client(context, "user:payments/@dee")
    removal = %{"owner" => "payments", "name" => "KEY"}

    assert {:ok, nil} = put(putter, "payments", "KEY")
    assert {:error, "forbidden", _message} = Client.run(putter, "secrets.delete", removal)
    assert {:error, "forbidden", _message} = put(remover, "payments", "OTHER")
    assert {:ok, nil} = Client.run(remover, "secrets.delete", removal)
    assert {:ok, %{"secrets" => []}} = list(putter, "payments")
  end
end
