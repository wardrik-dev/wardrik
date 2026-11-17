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
      Enum.reduce(Server.list_asks(), nil, fn {asked, input}, last ->
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

    assert_push_event(view, "composer:sent", %{})

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

  test "counts the calls waiting for approval in the sidebar and the tab's title", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/chat/triage")

    assert has_element?(view, ~s(.side a[href="/ops/chat/triage"] .count), "1")
    refute has_element?(view, ~s(.side a[href="/ops/chat/digest"] .count))
    assert page_title(view) =~ "(1) Triage desk"

    # The open chat shows its own call in line, not as a link to elsewhere.
    refute has_element?(view, ".elsewhere a")

    send(view.pid, :refresh)
    assert has_element?(view, ~s(.side a[href="/ops/chat/triage"] .count), "1")
  end

  test "links calls waiting in other chats", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, "/ops/chat/triage?conversation=web%202026-11-16%2010:00:00%20ab")

    assert has_element?(view, ~s(.elsewhere a[href="/ops/chat/triage"]), "github/open_issue")

    assert has_element?(
             view,
             ~s(#waiting-notify[data-text="Triage desk is waiting for your approval."])
           )
  end

  test "says what the agent does while it works, and asks in plain words" do
    html =
      render_component(&WardrikWeb.Timeline.timeline/1,
        items: [
          %{
            "kind" => "run",
            "status" => "waiting",
            "interrupts" => [
              %{"id" => "c1", "name" => "claude__execute", "arguments" => %{"command" => "ls ~"}}
            ]
          }
        ],
        drafts: %{},
        chat: true,
        doing: %{
          "since" => "2026-11-16T18:00:00Z",
          "doing" => [%{"type" => "wardrik.tool_call.started", "tool" => %{"name" => "claude"}}]
        }
      )

    assert html =~ "Using claude"
    assert html =~ ~s(data-since="2026-11-16T18:00:00Z")
    assert html =~ "Allow claude/execute?"
    assert html =~ "<dt>command</dt>"
    assert html =~ "<code>ls ~</code>"

    thinking = %{"doing" => [%{"type" => "wardrik.message.started"}]}

    html =
      render_component(&WardrikWeb.Timeline.timeline/1, items: [], drafts: %{}, doing: thinking)

    assert html =~ "Thinking"
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
