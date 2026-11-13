defmodule WardrikDaemon.WebTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, init_test_session: 2]
  import Phoenix.LiveViewTest
  import WardrikDaemon.Test

  alias WardrikDaemon.Client

  @endpoint WardrikDaemon.Web.Endpoint

  defp daemon(context, web) do
    context = dirs(context)
    port = free_port()

    write(context, "config.yaml", """
    org: payments
    http: {port: #{port}}
    web: {enabled: #{web}}
    defaults: {model: #{model()}}
    """)

    context = start_daemon(context)

    Map.merge(context, %{
      url: "http://127.0.0.1:#{port}",
      admin: %Client{url: "http://127.0.0.1:#{port}", secret: admin_secret(context)}
    })
  end

  defp admin_secret(context) do
    {:ok, %{secret: secret}} =
      WardrikDaemon.Tokens.create(context.daemon_store,
        name: "test",
        subject: "user:admin",
        expires: DateTime.add(DateTime.utc_now(), 1, :day)
      )

    secret
  end

  defp fetch(url, cookie \\ nil),
    do:
      Req.get!(url,
        redirect: false,
        retry: false,
        headers: if(cookie, do: [cookie: cookie], else: [])
      )

  test "signs in with a link, serves the dashboard and its pages, and signs out", context do
    context = daemon(context, true)

    assert fetch(context.url <> "/web").status == 302
    assert fetch(context.url <> "/web/sign-in").body =~ "wardrik web"

    assert {:ok, %{"url" => link}} = Client.run(context.admin, "tokens.web", %{})
    assert link =~ context.url <> "/web/sign-in?code="

    signed_in = fetch(link)
    assert signed_in.status == 302
    assert Req.Response.get_header(signed_in, "location") == ["/web"]
    [cookie] = Req.Response.get_header(signed_in, "set-cookie")
    cookie = hd(String.split(cookie, ";"))

    assert fetch(context.url <> "/web", cookie).body =~
             "All agents and conversations you can access."

    for {page, text} <- [
          {"secrets", "New secret"},
          {"servers", "New server"},
          {"x/tokens", "Create a token"}
        ],
        do: assert(fetch(context.url <> "/web/" <> page, cookie).body =~ text, page)

    assert fetch(context.url <> "/web/sign-in?code=nope").body =~ "expired"
    assert fetch(context.url <> "/web/sign-out", cookie).body =~ "signed out"
    assert fetch(context.url <> "/web", cookie).status == 302
  end

  test "is off with web.enabled false", context do
    context = daemon(context, false)

    assert {:error, "not_found", _message} = Client.run(context.admin, "tokens.web", %{})
    assert fetch(context.url <> "/web").status == 404
  end

  test "adds and removes secrets, servers and tokens from their pages", context do
    context = daemon(context, true)
    conn = init_test_session(build_conn(), %{"wardrik_token" => context.admin.secret})

    {:ok, secrets, _html} = live(conn, "/web/secrets")

    assert render_submit(secrets, "add", %{"input" => %{"name" => "api"}}) =~
             "Enter a name, a purpose and a value."

    html =
      render_submit(secrets, "add", %{
        "input" => %{"name" => "api", "purpose" => "api_key", "value" => "s3cret"}
      })

    assert html =~ "Added api."
    refute html =~ "s3cret"

    assert render_click(secrets, "remove", %{"name" => "api"}) =~ "Removed api."
    assert render_change(element(secrets, "#owner-picker"), %{"owner" => "payments"})

    {:ok, servers, _html} = live(conn, "/web/servers")
    assert render_submit(servers, "add", %{"input" => %{"name" => ""}}) =~ "flash error"

    input = %{
      "name" => "docs",
      "url" => "https://mcp.example.com/mcp",
      "auth" => %{"__variant" => "0"}
    }

    render_change(servers, "change", %{"input" => input})
    assert render_submit(servers, "add", %{"input" => input}) =~ "docs"
    assert render_click(servers, "remove", %{"name" => "nope"}) =~ "nope"

    {:ok, tokens, _html} = live(conn, "/web/x/tokens")
    assert render_submit(tokens, "create", %{"input" => %{"name" => ""}}) =~ "flash error"

    input = %{"name" => "laptop", "subject" => "user:payments/@ana"}
    render_change(tokens, "change", %{"input" => input})
    assert render_submit(tokens, "create", %{"input" => input}) =~ "laptop"
    render_click(tokens, "dismiss", %{})

    [%{"id" => id}] =
      for token <-
            Enum.map(
              WardrikDaemon.Tokens.list(context.daemon_store),
              &WardrikDaemon.Tokens.json/1
            ),
          token["name"] == "laptop",
          do: token

    assert render_click(tokens, "revoke", %{"id" => id}) =~ "Revoked the token."
  end

  test "lists notify targets, OAuth apps, connections, ceilings and the configuration", context do
    context = daemon(context, true)
    write(context, "policies/plan.yaml", "budget: {usd: 20.00, per: month}\n")
    conn = init_test_session(build_conn(), %{"wardrik_token" => context.admin.secret})

    {:ok, notify, html} = live(conn, "/web/notify")
    assert html =~ "Notify targets"
    assert render_submit(notify, "add", %{"input" => %{"name" => ""}}) =~ "flash error"
    assert render_click(notify, "remove", %{"name" => "none"}) =~ "flash error"
    render_change(notify, "change", %{"input" => %{"name" => "ops"}})
    render_click(notify, "dismiss", %{})
    render_change(element(notify, "#owner-picker"), %{"owner" => "deployment"})

    {:ok, oauth, html} = live(conn, "/web/oauth")
    assert html =~ "OAuth apps"

    oauth
    |> form("#settings-form", %{
      "input" => %{
        "name" => "google",
        "authorization_endpoint" => "https://accounts.google.com/o/oauth2/auth",
        "token_endpoint" => "https://oauth2.googleapis.com/token",
        "client_id" => "abc"
      }
    })
    |> render_submit()

    assert render(oauth) =~ "google"
    assert render_click(oauth, "remove", %{"name" => "google"}) =~ "Removed google."

    {:ok, connections, html} = live(conn, "/web/connections")
    assert html =~ "Connections"
    assert render_click(connections, "connect", %{"provider" => "nope"}) =~ "flash error"
    assert render_click(connections, "disconnect", %{"provider" => "nope"}) =~ "flash error"

    assert render_submit(connections, "pair", %{"provider" => "nope", "code" => "AAAA-BBBB"}) =~
             "flash error"

    render_click(connections, "cancel", %{})
    send(connections.pid, :refresh)

    {:ok, _ceilings, html} = live(conn, "/web/x/ceilings")
    assert html =~ "Ceilings"

    {:ok, _config, html} = live(conn, "/web/x/config")
    assert html =~ "config.yaml"
    assert html =~ "wardrik reload"
  end

  test "hides secrets written directly in config.yaml", context do
    context = daemon(context, true)
    write(context, "policies/keys.yaml", "api_key: sk-plain-123\ntoken: ${TOKEN}\n")
    conn = init_test_session(build_conn(), %{"wardrik_token" => context.admin.secret})

    {:ok, _config, html} = live(conn, "/web/x/config")
    refute html =~ "sk-plain-123"
    assert html =~ "(hidden)"
    assert html =~ "${TOKEN}"
  end
end
