defmodule WardrikDaemon.EgressTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias Wardrik.Notice
  alias Wardrik.Resolver.Request
  alias WardrikDaemon.Client
  alias WardrikDaemon.Config
  alias WardrikDaemon.Tokens

  setup :set_mimic_global

  @inside [
    "http://127.0.0.1:1/mcp",
    "https://127.0.0.1/mcp",
    "http://169.254.169.254/latest/meta-data",
    "https://169.254.169.254/mcp",
    "https://10.0.0.5/mcp",
    "https://192.168.1.2/mcp",
    "https://[::1]/mcp"
  ]

  setup context do
    context = dirs(context)
    port = free_port()

    write(context, "config.yaml", """
    org: payments
    orgs: {growth: {}}
    allow_private_urls: #{Map.get(context, :private, false)}
    http: {port: #{port}}
    defaults: {model: #{model()}}
    mcp:
      local: {url: "http://127.0.0.1:1/local"}
    """)

    context = start_daemon(context)

    {:ok, %{secret: secret}} =
      Tokens.create(context.daemon_store,
        name: "test",
        subject: "user:admin",
        expires: DateTime.add(DateTime.utc_now(), 1, :hour)
      )

    Map.merge(context, %{
      admin: %Client{url: "http://127.0.0.1:#{port}", secret: secret},
      running: Wardrik.Instance.fetch!(context.wardrik)
    })
  end

  defp server(context, url, auth \\ %{"none" => %{}}),
    do:
      Client.run(context.admin, "servers.add", %{
        "owner" => "growth",
        "name" => "s#{System.unique_integer([:positive])}",
        "url" => url,
        "auth" => auth
      })

  defp target(context, url),
    do:
      Client.run(context.admin, "notify_targets.add", %{
        "owner" => "growth",
        "name" => "t#{System.unique_integer([:positive])}",
        "url" => url
      })

  test "refuses what an owner adds at a loopback, private, link-local or metadata address",
       context do
    for url <- @inside do
      assert {:error, "invalid_request", "The server can't be reached: " <> _why} =
               server(context, url)

      assert {:error, "invalid_request", "The target can't be reached: " <> _why} =
               target(context, url)
    end

    oauth = %{
      "authorization_endpoint" => "https://auth.example.com/authorize",
      "token_endpoint" => "https://169.254.169.254/token",
      "client_id" => "app"
    }

    assert {:error, "invalid_request", "The server can't be reached: " <> _why} =
             server(context, "https://mcp.example.com/mcp", %{"oauth" => oauth})

    assert [] = Enum.filter(WardrikMCP.servers(Wardrik.mcp(context.wardrik)), &(&1 =~ "growth"))

    # config.yaml's own server is trusted where it is.
    request = %Request{agent: recorded(context, "payments/x")}
    {:ok, resolved} = Wardrik.Resolver.resolve(context.running, request)
    assert resolved.servers["local"] == "local"
  end

  @tag private: true
  test "lets an owner add them with allow_private_urls, for local use", context do
    for url <- ["http://127.0.0.1:1/mcp", "https://10.0.0.5/mcp"] do
      assert {:ok, %{"connected" => true}} = server(context, url)
      assert {:ok, %{"url" => ^url}} = target(context, url)
    end
  end

  test "sends no notice to a webhook whose host resolves privately as it's sent", context do
    stub(Wardrik.Egress, :public, fn
      "https://localhost/hook" -> :ok
      url -> call_original(Wardrik.Egress, :public, [url])
    end)

    assert {:ok, %{"name" => name}} = target(context, "https://localhost/hook")

    stub(Wardrik.Egress, :public, fn url -> call_original(Wardrik.Egress, :public, [url]) end)

    notice = %Notice{
      agent: recorded(context, "growth/leads"),
      kind: :failed,
      at: DateTime.utc_now(),
      reason: "x"
    }

    assert {:skip, "but it can't be reached: localhost is at " <> _address} =
             Wardrik.Notify.deliver(context.running, name, notice)
  end

  test "trusts the hosts config.yaml's OAuth providers name, and nothing else", context do
    config = %Config{
      oauth: [providers: [idp: [issuer: "https://idp.internal.test", client_id: "agents"]]]
    }

    check = WardrikDaemon.Egress.check(config)
    assert check.("https://idp.internal.test/token") == :ok
    assert {:error, _why} = check.("https://10.0.0.5/token")

    assert WardrikDaemon.Egress.check(%{config | allow_private_urls: true}).("http://10.0.0.5") ==
             :ok

    assert context.running.egress.("https://169.254.169.254/") != :ok
  end
end
