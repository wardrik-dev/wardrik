defmodule WardrikWeb.AgentChangesTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias WardrikWeb.Test.Server

  @endpoint WardrikWeb.Test.Endpoint

  setup do
    %{conn: build_conn() |> Plug.Test.init_test_session(%{"user" => "ana"})}
  end

  defp asked(id), do: for({^id, input} <- Server.asked(), do: input)

  test "edits a definition and keeps its triggers", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/agents/triage?tab=definition")
    assert render(view) =~ "Triage issues."

    view |> element("button", "Edit") |> render_click()
    view |> form("#definition-form", %{"input" => %{"model" => "zai:glm-5"}}) |> render_change()
    view |> form("#definition-form") |> render_submit()

    assert %{"agent" => "triage", "model" => "zai:glm-5", "triggers" => [%{"name" => "sweep"}]} =
             List.last(asked("agent.define"))
  end

  test "adds and removes triggers", %{conn: conn} do
    {:ok, view, html} = live(conn, "/ops/agents/triage?tab=triggers")
    assert html =~ "sweep"

    view |> element("button", "Add trigger") |> render_click()

    view
    |> form("#trigger-form", %{
      "input" => %{"trigger" => "daily", "every" => "0 9 * * *", "prompt" => "Report."}
    })
    |> render_submit()

    assert %{"agent" => "triage", "trigger" => "daily", "every" => "0 9 * * *"} =
             List.last(asked("agent.trigger_set"))

    view |> element("button", "Remove") |> render_click()
    assert %{"agent" => "triage", "trigger" => "sweep"} = List.last(asked("agent.trigger_remove"))
  end

  test "moves and forgets an agent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/agents/triage")

    view |> form("#move-form", %{"node" => "b@host"}) |> render_submit()
    assert %{"agent" => "triage", "node" => "b@host"} = List.last(asked("agent.move"))

    assert {:error, {:live_redirect, %{to: "/ops"}}} =
             view |> element("button", "Forget") |> render_click()

    assert %{"agent" => "triage"} = List.last(asked("agent.forget"))
  end

  test "defines a new agent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/new")

    assert view |> form("#new-agent", %{"agent_id" => ""}) |> render_submit() =~
             "Give the agent an ID."

    assert {:error, {:live_redirect, %{to: "/ops/agents/scout?tab=definition"}}} =
             view
             |> form("#new-agent", %{
               "agent_id" => "scout",
               "input" => %{"model" => "zai:glm", "tools" => "web_search\nfiles"}
             })
             |> render_submit()

    assert %{"agent" => "scout", "model" => "zai:glm", "tools" => ["web_search", "files"]} =
             List.last(asked("agent.define"))
  end
end
