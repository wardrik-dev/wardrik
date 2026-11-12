defmodule WardrikWeb.SettingsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias WardrikWeb.Test.Connections
  alias WardrikWeb.Test.Servers

  @endpoint WardrikWeb.Test.Endpoint

  setup do
    Servers.reset()
    Connections.reset()
    %{conn: build_conn() |> Plug.Test.init_test_session(%{"user" => "ana"})}
  end

  test "lists the settings pages, and marks the ones that are off", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops")

    assert has_element?(view, "a.nav:not(.off)", "MCP servers")
    assert has_element?(view, "a.nav.off", "Notify targets")
    assert has_element?(view, "a.nav.off", "OAuth apps")

    {:ok, _view, html} = live(conn, "/ops/notify")
    assert html =~ "This page is off"
    assert html =~ "WardrikWeb.Settings"
    assert html =~ "notify_targets: {MyApp.WardrikNotifyTargets, []}"

    {:ok, _view, html} = live(conn, "/ops/oauth")
    assert html =~ "This page is off"
  end

  test "lists an owner's servers, with the ones it can't remove", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/servers")

    assert html =~ "MCP servers"
    assert html =~ "https://crm.test/mcp"
    assert html =~ "a b"
    assert html =~ "Set in config.yaml"
    assert html =~ "Belongs to deployment"
    assert has_element?(view, "button[phx-value-name=crm]", "Remove")
    refute has_element?(view, "button[phx-value-name=github]")
    refute has_element?(view, "button[phx-value-name=search]")
    assert has_element?(view, "input[type=password][name='input[token]']")

    view |> element("#owner-picker") |> render_change(%{"owner" => "ana"})
    assert_patch(view, "/ops/servers?owner=ana")
    assert render(view) =~ "search"
    refute render(view) =~ "crm.test"
  end

  test "adds and removes a server", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/servers")

    view |> form("#settings-form", %{"input" => %{"name" => ""}}) |> render_change()
    html = view |> form("#settings-form", %{"input" => %{"name" => ""}}) |> render_submit()
    assert html =~ "Fill in the server&#39;s required fields."

    html = view |> form("#settings-form", %{"input" => %{"name" => "bad"}}) |> render_submit()
    assert html =~ "That name is taken."

    html =
      view
      |> form("#settings-form", %{"input" => %{"name" => "jira", "url" => "https://jira.test"}})
      |> render_submit()

    assert html =~ "Added jira."
    assert html =~ "https://jira.test"
    refute view |> element("button", "Done") |> render_click() =~ ~s("owner": "acme")

    assert view |> element("button[phx-value-name=jira]") |> render_click() =~ "Removed jira."
    refute render(view) =~ "jira.test"
  end

  test "shows the error a source returns", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/servers")
    assert render_click(view, "remove", %{"name" => "github"}) =~ "It&#39;s in config.yaml."

    {:ok, _view, html} = live(conn, "/ops/servers?owner=nobody")
    assert html =~ "Not yours."
    refute html =~ "settings-form"
  end

  test "keeps a secret's value out of the page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/secrets")

    assert html =~ "API_KEY"
    refute has_element?(view, "#owner-picker")
    refute html =~ "More settings"
    assert has_element?(view, "input[type=password][name='input[value]']")

    html =
      view
      |> form("#settings-form", %{"input" => %{"name" => "TOKEN", "value" => "s3cret"}})
      |> render_submit()

    assert html =~ "Added TOKEN."
    refute html =~ "s3cret"
  end

  test "connects and disconnects accounts", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/connections")

    assert html =~ "signing in"
    assert html =~ "not connected"

    assert view |> element("button[phx-value-provider=google]") |> render_click() =~
             "Disconnected google."

    assert render_click(view, "connect", %{"provider" => "google"}) =~
             "google is already connected."

    html = view |> element("button[phx-value-provider=github]") |> render_click()
    assert html =~ "ABCD-1234"
    assert html =~ "https://github.test/device"

    Connections.connected("github")
    send(view.pid, :refresh)
    refute render(view) =~ "ABCD-1234"

    html = view |> element("button[phx-value-provider=linear]") |> render_click()
    assert html =~ "Enter the code here"
    assert view |> form("#pair-form", %{"code" => "BAD"}) |> render_submit() =~ "Wrong code."

    assert view |> form("#pair-form", %{"code" => " GOOD "}) |> render_submit() =~
             "Connected linear."

    refute has_element?(view, "#signing-in")

    view |> element("button[phx-value-provider=slack]", "Connect") |> render_click()
    assert render(view) =~ "slack isn&#39;t set up."

    assert render_click(view, "disconnect", %{"provider" => "slack"}) =~
             "Slack can&#39;t be disconnected."

    html = view |> element("button[phx-value-provider=linear]") |> render_click()
    assert html =~ "Disconnected linear."
    view |> element("button[phx-value-provider=linear]") |> render_click()
    view |> element("#signing-in button", "Cancel") |> render_click()
    refute has_element?(view, "#signing-in")
  end

  test "shows what an agent gets", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/ops/agents/triage?tab=access")

    assert html =~ "user_42"
    assert html =~ "acme:github"
    assert html =~ "1 tools"
    assert html =~ "no tools now"
    assert html =~ "shell/*"
    assert html =~ "Named policy"
    assert html =~ "Sent by your app"
    assert html =~ "T0123"
    assert html =~ "read only"
    assert html =~ "zai:glm"
  end
end
