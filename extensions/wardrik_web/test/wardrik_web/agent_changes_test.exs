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
             view |> element("button", "Delete") |> render_click()

    assert %{"agent" => "triage"} = List.last(asked("agent.forget"))
  end

  test "defines a new agent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/new")

    assert view |> form("#new-agent", %{"agent_id" => ""}) |> render_submit() =~
             "Enter an agent ID."

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

  test "edits a trigger, renames it and checks its name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/agents/triage?tab=triggers")

    view |> element("button", "Edit") |> render_click()
    view |> element("#trigger-form button", "Cancel") |> render_click()
    view |> element("button", "Edit") |> render_click()

    view
    |> form("#trigger-form", %{"input" => %{"trigger" => "", "every" => "0 * * * *"}})
    |> render_change()

    view
    |> form("#trigger-form", %{"input" => %{"trigger" => "", "every" => "0 * * * *"}})
    |> render_submit()

    assert render(view) =~ "Enter a trigger name."

    view
    |> form("#trigger-form", %{"input" => %{"trigger" => "hourly", "every" => "0 * * * *"}})
    |> render_submit()

    assert render(view) =~ "Saved hourly."
    assert %{"trigger" => "hourly"} = List.last(asked("agent.trigger_set"))
    assert %{"trigger" => "sweep"} = List.last(asked("agent.trigger_remove"))
  end

  test "asks, denies, and runs an agent's actions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ops/agents/triage")

    view |> form(".composer", %{"content" => "Any news?"}) |> render_submit()
    assert %{"agent" => "triage"} = List.last(asked("agent.ask"))

    render_click(view, "deny", %{"interrupt" => "toolu_1"})
    assert [_ | _] = asked("agent.deny")

    for action <- ~w(cancel stop clear spawn) do
      assert render_click(view, action, %{}) =~ "flash info"
      assert [%{"agent" => "triage"} | _rest] = asked("agent." <> action)
    end

    render_click(view, "kill", %{"call" => "toolu_1"})
    assert %{"call" => "toolu_1"} = List.last(asked("agent.kill"))
    render_click(view, "move", %{"node" => ""})
  end
end
