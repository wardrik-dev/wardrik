defmodule WardrikWeb.DashboardTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias WardrikWeb.Test.Server

  @endpoint WardrikWeb.Test.Endpoint

  setup do
    conn = Plug.Test.init_test_session(build_conn(), %{"user" => "ana"})
    %{conn: conn}
  end

  test "sends a person the resolver refuses to sign in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), "/ops")
  end

  test "lists agents, with the extension's panel and page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops")

    assert html =~ "triage"
    assert html =~ "Panel sees 2 agents"
    assert has_element?(view, "a.nav", "Extra")

    html =
      view
      |> element("form.filters")
      |> render_change(%{"only" => "idle"})

    assert html =~ "digest"

    html =
      view
      |> element("form.filters")
      |> render_change(%{"only" => "idle"})

    refute html =~ ">triage<"

    {:ok, _extra, extra} = live(conn, "/ops/x/extra")
    assert extra =~ "Extra page for ana"
  end

  test "approves a call from an agent's timeline", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/agents/triage")

    assert html =~ "File the flaky test"
    assert html =~ "Open an issue?"

    view
    |> form(".ask form", %{"note" => "ok"})
    |> render_submit()

    assert {"agent.approve", %{"agent" => "triage", "interrupt" => "toolu_1", "note" => "ok"}} in Server.asked()
  end

  test "shows the error an operation answers", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/ops/agents/missing")
    assert html =~ "There&#39;s no such agent."
  end

  test "rejects from the approvals page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/approvals")

    view
    |> element("button", "Reject")
    |> render_click()

    assert {"agent.deny", %{"agent" => "triage", "interrupt" => "toolu_1"}} in Server.asked()
  end

  test "runs any operation from its form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/operations/deployment.nodes")

    html =
      view
      |> form("#operation-form")
      |> render_submit()

    assert html =~ "a@host"

    {:ok, view, _html} = live(conn, "/ops/operations/agent.ask")

    html =
      view
      |> form("#operation-form")
      |> render_submit(%{"input" => %{"agent" => "triage", "content" => "Hi"}})

    assert html =~ "m2"
    assert {"agent.ask", %{"agent" => "triage", "content" => "Hi"}} in Server.asked()
  end

  test "decides several calls with groups added to the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/operations/agent.decide")

    view
    |> element("button", "Add decisions")
    |> render_click()

    view
    |> element("button", "Add decisions")
    |> render_click()

    view
    |> form("#operation-form", %{
      "input" => %{
        "agent" => "triage",
        "decisions" => %{
          "0" => %{"id" => "toolu_1", "decision" => "approve"},
          "1" => %{"id" => "toolu_2", "decision" => "reject", "reason" => "No."}
        }
      }
    })
    |> render_submit()

    assert {"agent.decide",
            %{
              "agent" => "triage",
              "decisions" => [
                %{"id" => "toolu_1", "decision" => "approve"},
                %{"id" => "toolu_2", "decision" => "reject", "reason" => "No."}
              ]
            }} in Server.asked()
  end

  test "keeps operations other systems call apart, and finds operations", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/operations")
    assert html =~ "Called by webhooks and chat apps"
    assert html =~ "hook.deliver"

    html =
      view
      |> form("#operations-filter", %{"query" => "trigger"})
      |> render_change()

    assert html =~ "agent.trigger_set"
    refute html =~ "agents.list"

    {:ok, _view, html} = live(conn, "/ops/operations/hook.deliver")
    assert html =~ "Webhooks and chat apps call this operation"
  end

  test "serves its assets", %{conn: conn} do
    {js, css} = WardrikWeb.Assets.names()
    assert response(get(conn, "/ops/assets/" <> js), 200) =~ "LiveSocket"
    assert response(get(conn, "/ops/assets/" <> css), 200) =~ ":root"
    assert response(get(conn, "/ops/assets/nope.js"), 404)
  end

  test "follows a stream and shows a run's error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/operations/events.list")
    render_click(view, "follow", %{"input" => %{"agents" => "triage"}})
    render_change(view, "change", %{"input" => %{"agents" => "triage"}})
    assert render_click(view, "run", %{"input" => %{"agents" => "triage"}}) =~ "Not in this test."
  end

  test "shows the audit log and loads more", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/audit")
    assert html =~ "agent.defined"
    render_click(view, "more", %{})
    assert {"audit.list", %{"limit" => 100, "starting_after" => 1}} in Server.asked()
  end

  test "lists nodes and reloads definitions", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/nodes")
    assert html =~ "wardrik@box1"
    assert html =~ "working"
    assert html =~ "wait on a person"
    refute html =~ "agents running"
    assert render_click(view, "reload", %{}) =~ "Reloaded agent definitions."
    send(view.pid, :tick)
    assert render(view) =~ "wardrik@box1"
  end

  test "shows an agent's runs, running calls and events", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/ops/agents/triage?tab=runs")
    assert html =~ "The model timed out."
    assert html =~ "1.2M"

    {:ok, _view, html} = live(conn, "/ops/agents/triage?tab=calls")
    assert html =~ "github__search"

    {:ok, view, html} = live(conn, "/ops/agents/triage?tab=events")
    assert html =~ "run.started"
    assert html =~ "Calling github__search"
    assert render(view) =~ "triage"
  end

  test "approves from the approvals page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/approvals")
    render_submit(view, "approve", %{"agent" => "triage", "interrupt" => "toolu_1", "note" => ""})
    assert {"agent.approve", %{"agent" => "triage", "interrupt" => "toolu_1"}} in Server.asked()
  end

  test "shows tool and delegate steps, and drafts while a reply streams", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/agents/triage")
    assert html =~ "Rate limited."
    assert html =~ "Found two reports."

    delta = %{
      "id" => "d1",
      "type" => "wardrik.message.delta",
      "data" => %{"message" => %{"id" => "m9"}, "delta" => "Draft"}
    }

    send(view.pid, {WardrikWeb.Follow, {:event, delta}})

    send(
      view.pid,
      {WardrikWeb.Follow, {:event, %{delta | "data" => %{delta["data"] | "delta" => "ing"}}}}
    )

    assert render(view) =~ "Drafting"

    done = %{
      "id" => "d2",
      "type" => "wardrik.message.completed",
      "data" => %{"message" => %{"id" => "m9"}}
    }

    send(view.pid, {WardrikWeb.Follow, {:event, done}})
    send(view.pid, {WardrikWeb.Follow, :reload})
    refute render(view) =~ "Drafting"
  end

  test "sends an unknown operation back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/ops/operations"}}} =
             live(conn, "/ops/operations/nope")
  end

  test "shows each node's resource use and the agents that use the most memory", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/nodes")
    assert html =~ "Scheduler use"
    assert html =~ "12%"
    assert html =~ "94 MB"
    assert html =~ "Agents by memory"
    assert html =~ "Disk /"
    assert html =~ "BEAM memory"
    assert html =~ "156 MB in the OS"
    assert html =~ "Persistent terms"
    assert html =~ "Other"
    assert html =~ "What runs on this node"
    assert html =~ "thousand_island"
    assert html =~ "WardrikCore.Agent"
    assert html =~ "No application"
    assert html =~ "data-tip="

    send(view.pid, :tick)
    html = render(view)
    assert html =~ "<polyline"
    assert html =~ "/s" or html =~ "Work per second"
  end

  test "shows a running agent's memory and mailbox", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/agents/triage")
    assert html =~ "1.8 MB"
    send(view.pid, :runtime)
    assert render(view) =~ "0/s"
  end

  test "links to the documentation", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/ops")
    assert html =~ ~s(href="https://wardrik.dev")
  end
end
