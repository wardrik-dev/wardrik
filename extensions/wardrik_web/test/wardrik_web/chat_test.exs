defmodule WardrikWeb.ChatTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias WardrikWeb.Test.Server

  @endpoint WardrikWeb.Test.Endpoint

  setup do
    %{conn: Plug.Test.init_test_session(build_conn(), %{"user" => "ana"})}
  end

  defp last(id),
    do:
      Enum.reduce(Server.asked(), nil, fn {asked, input}, last ->
        if(asked == id, do: input, else: last)
      end)

  test "lists the agents to chat with, and links the dashboard both ways", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/chat")

    assert html =~ "Pick an agent to chat with."
    assert has_element?(view, ~s(a[href="/ops/chat/triage"]))
    assert has_element?(view, ~s(.side a[href="/ops"]), "Dashboard")

    {:ok, dashboard, _html} = live(conn, "/ops")
    assert has_element?(dashboard, ~s(a.nav[href="/ops/chat"]), "Chat")
  end

  test "chats with an agent: its answers as markdown, approvals, and asking", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/chat/triage")

    assert html =~ "File the flaky test"
    assert html =~ "<h1>Triage desk"
    assert html =~ ~s(placeholder="Message Triage desk")
    assert html =~ "<p>Opening an issue.</p>"
    refute html =~ "zai:glm"
    assert html =~ "Open an issue?"
    assert has_element?(view, ~s(a[href="/ops/agents/triage"]), "Details")

    view
    |> form(".composer", %{"content" => "Any news?"})
    |> render_submit()

    assert %{"agent" => "triage", "content" => "Any news?"} =
             last("agent.ask")

    view
    |> form(".ask form", %{"note" => "ok"})
    |> render_submit()

    assert %{"agent" => "triage", "interrupt" => "toolu_1"} =
             last("agent.approve")
  end

  test "starts a new chat, which reads as empty until its first message", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/chat/triage")

    render_click(view, "new", %{})
    assert {path, _flash} = assert_redirect(view)
    assert %URI{path: "/ops/chat/triage", query: query} = URI.parse(path)
    assert %{"conversation" => "web " <> _stamp = conversation} = URI.decode_query(query)

    {:ok, _chat, html} = live(conn, path)
    refute html =~ "no such"
    assert html =~ conversation
  end

  test "drops raw HTML and unsafe links from markdown" do
    html =
      render_component(&WardrikWeb.Timeline.markdown/1,
        text: "**bold** <script>alert(1)</script> [x](javascript:alert(1))"
      )

    assert html =~ "<strong>bold</strong>"
    refute html =~ "<script>"
    refute html =~ "javascript:"
  end
end
