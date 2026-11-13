defmodule WardrikDaemon.NotifyTargetsTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias Wardrik.Notice
  alias Wardrik.Resolver.Request
  alias Wardrik.Vault.Secret
  alias WardrikCore.Principal
  alias WardrikDaemon.Client
  alias WardrikDaemon.Tokens

  setup :set_mimic_global

  defmodule Hooks do
    @moduledoc "Tells the test each request a webhook gets. `/moved` redirects to `/inside`."
    @behaviour Plug

    @impl Plug
    def init(test), do: test

    @impl Plug
    def call(%{request_path: "/moved"} = conn, test) do
      send(test, {:hooked, "/moved", nil, nil})

      conn
      |> Plug.Conn.put_resp_header("location", "/inside")
      |> Plug.Conn.send_resp(302, "")
    end

    def call(conn, test) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:hooked, conn.request_path, Map.new(conn.req_headers), body})
      Plug.Conn.send_resp(conn, 204, "")
    end
  end

  setup context do
    context = dirs(context)
    port = free_port()
    hooks = free_port()
    start_supervised!({Bandit, plug: {Hooks, self()}, port: hooks, ip: {127, 0, 0, 1}})

    write(context, "config.yaml", """
    org: payments
    orgs: {growth: {}}
    allow_private_urls: true
    http: {port: #{port}}
    defaults: {model: #{model()}}
    notify:
      targets:
        audit: {webhook: {url: "http://127.0.0.1:#{hooks}/audit"}}
    roles:
      adder: {rules: [{verbs: [add, read], kinds: [notify_target]}]}
      remover: {rules: [{verbs: [delete, read], kinds: [notify_target]}]}
    bindings:
      - {org: payments, role: operator, subjects: [user:payments/@ana]}
      - {org: payments, role: adder, subjects: [user:payments/@bo]}
      - {org: payments, role: remover, subjects: [user:payments/@dee]}
    """)

    context = start_daemon(context)

    Map.merge(context, %{
      url: "http://127.0.0.1:#{port}",
      hooks: "http://127.0.0.1:#{hooks}",
      running: Wardrik.Instance.fetch!(context.wardrik)
    })
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

  defp target(context, name, fields \\ %{}),
    do: Map.merge(%{"name" => name, "url" => "#{context.hooks}/#{name}"}, fields)

  defp add(client, owner, input),
    do: Client.run(client, "notify_targets.add", Map.put(input, "owner", owner))

  defp list(client, owner), do: Client.run(client, "notify_targets.list", %{"owner" => owner})

  defp remove(client, owner, name),
    do: Client.run(client, "notify_targets.remove", %{"owner" => owner, "name" => name})

  defp seal(context, owner, name, value) do
    secret = %Secret{principal: %Principal{id: owner}, name: name, value: value}

    {:ok, _vsn} =
      Wardrik.Vault.put(Wardrik.vault(context.running), secret, kind: :signing_secret)
  end

  defp notify(context, id) do
    request = %Request{agent: recorded(context, id)}
    {:ok, resolved} = Wardrik.Resolver.resolve(context.running, request)
    resolved.notify
  end

  defp deliver(context, id, name) do
    notice = %Notice{
      agent: recorded(context, id),
      kind: :failed,
      at: DateTime.utc_now(),
      reason: "x"
    }

    Wardrik.Notify.deliver(context.running, name, notice)
  end

  test "an owner's webhook reaches only the agents the resolver gives it to", context do
    admin = client(context, "user:admin")

    for owner <- ["payments", "payments/@ana", "growth"],
        do: {:ok, _added} = add(admin, owner, target(context, "ops"))

    assert {Wardrik.Notify.OwnedWebhook, opts} = notify(context, "payments/@ana/notes")["ops"]
    assert opts[:owner] == "payments/@ana"
    assert {Wardrik.Notify.OwnedWebhook, opts} = notify(context, "payments/@bo/notes")["ops"]
    assert opts[:owner] == "payments"
    assert notify(context, "payments/triage")["audit"] == "audit"
    refute Map.has_key?(notify(context, "growth/leads"), "audit")

    assert :ok = deliver(context, "payments/@bo/notes", "ops")
    assert_receive {:hooked, "/ops", _headers, body}
    assert JSON.decode!(body)["agent"] == recorded(context, "payments/@bo/notes")

    assert {:ok, %{"name" => "ops", "owner" => "growth"}} = remove(admin, "growth", "ops")
    assert {:skip, _why} = deliver(context, "growth/leads", "ops")
    refute_received {:hooked, _path, _headers, _body}

    assert {:ok, %{"targets" => listed}} = list(admin, "payments/@ana")

    assert for(target <- listed, do: {target["owner"], target["name"], target["source"]}) == [
             {"payments/@ana", "ops", "runtime"}
           ]
  end

  test "a token bound in one org can't add, list or remove another org's targets", context do
    admin = client(context, "user:admin")
    ana = client(context, "user:payments/@ana")
    {:ok, _added} = add(admin, "growth", target(context, "ops"))

    assert {:ok, %{"name" => "mine"}} = add(ana, "payments", target(context, "mine"))

    for owner <- ["growth", "growth/@cy", "deployment"] do
      assert {:error, "not_found", _message} = list(ana, owner)
      assert {:error, "not_found", _message} = add(ana, owner, target(context, "theirs"))
      assert {:error, "not_found", _message} = remove(ana, owner, "ops")
    end

    assert {:ok, %{"targets" => [%{"name" => "ops"}]}} = list(admin, "growth")
  end

  test "signs with a secret named, read as each notice is sent, never kept or answered",
       context do
    admin = client(context, "user:admin")
    signed = target(context, "signed", %{"secret" => %{"name" => "HOOK_SECRET"}})

    assert {:error, "invalid_request", message} = add(admin, "growth", signed)
    assert message == "growth holds no secret HOOK_SECRET sealed as a signing_secret."

    seal(context, "growth", "HOOK_SECRET", "first-shh")

    assert {:ok, %{"secret" => %{"name" => "HOOK_SECRET"}} = added} =
             add(admin, "growth", signed)

    refute JSON.encode!(added) =~ "shh"
    assert {:ok, answer} = list(admin, "growth")
    refute JSON.encode!(answer) =~ "shh"
    refute :erlang.term_to_binary(Wardrik.Store.entries(context.daemon_store, "")) =~ "shh"

    assert :ok = deliver(context, "growth/leads", "signed")
    assert_receive {:hooked, "/signed", headers, body}
    assert headers["x-wardrik-signature"] == Wardrik.Notify.Webhook.sign("first-shh", body)

    seal(context, "growth", "HOOK_SECRET", "rotated-shh")
    assert :ok = deliver(context, "growth/leads", "signed")
    assert_receive {:hooked, "/signed", headers, body}
    assert headers["x-wardrik-signature"] == Wardrik.Notify.Webhook.sign("rotated-shh", body)

    :ok =
      Wardrik.Vault.delete(
        Wardrik.vault(context.running),
        %Principal{id: "growth"},
        "HOOK_SECRET"
      )

    assert deliver(context, "growth/leads", "signed") ==
             {:skip, "but growth holds no secret HOOK_SECRET to sign it with"}
  end

  test "checks a URL as it's added and as each notice is sent, following no redirect",
       context do
    stub(Wardrik.Egress, :any, fn url ->
      if url =~ "169.254.169.254", do: {:error, "169.254.169.254 is a private address"}, else: :ok
    end)

    admin = client(context, "user:admin")
    inside = %{target(context, "inside") | "url" => "https://169.254.169.254/latest"}

    assert {:error, "invalid_request", message} = add(admin, "growth", inside)
    assert message == "The target can't be reached: 169.254.169.254 is a private address."

    {:ok, _added} = add(admin, "growth", target(context, "moved"))
    assert {:error, {:status, 302}} = deliver(context, "growth/leads", "moved")
    assert_receive {:hooked, "/moved", nil, nil}
    refute_received {:hooked, "/inside", _headers, _body}

    stub(Wardrik.Egress, :any, fn _url -> {:error, "it resolves inside now"} end)

    assert deliver(context, "growth/leads", "moved") ==
             {:skip, "but it can't be reached: it resolves inside now"}

    refute_received {:hooked, "/moved", _headers, _body}
  end

  test "refuses a target that doesn't read, one it holds, and one config.yaml starts", context do
    admin = client(context, "user:admin")

    for input <- [
          target(context, "slack:#ops"),
          Map.delete(target(context, "x"), "url"),
          Map.put(target(context, "x"), "secret", "shh"),
          Map.put(target(context, "x"), "module", "Wardrik.Notify.Room")
        ] do
      assert {:error, "invalid_request", _message} = add(admin, "growth", input)
    end

    {:ok, _added} = add(admin, "growth", target(context, "ops"))
    assert {:error, "conflict", _message} = add(admin, "growth", target(context, "ops"))
    assert {:error, "conflict", _message} = add(admin, "deployment", target(context, "audit"))
    assert {:error, "invalid_request", _message} = remove(admin, "deployment", "audit")
    assert {:error, "not_found", _message} = remove(admin, "growth", "nope")

    assert {:ok, %{"events" => events}} = Wardrik.run(context.admin, "audit.list", %{})
    assert "wardrik.notify_target.added" in Enum.map(events, & &1["type"])
  end

  # Removing is its own verb, as Kubernetes' delete: adding doesn't allow it.
  test "removing a target needs delete, not add", context do
    adder = client(context, "user:payments/@bo")
    remover = client(context, "user:payments/@dee")

    assert {:ok, _added} = add(adder, "payments", target(context, "ops"))
    assert {:error, "forbidden", _message} = remove(adder, "payments", "ops")
    assert {:error, "forbidden", _message} = add(remover, "payments", target(context, "docs"))
    assert {:ok, _removed} = remove(remover, "payments", "ops")
    assert {:ok, %{"targets" => targets}} = list(adder, "payments")
    refute "ops" in Enum.map(targets, & &1["name"])
  end
end
