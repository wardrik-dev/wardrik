defmodule Wardrik.Agent.Activity.EnglishTest do
  use ExUnit.Case, async: true

  alias Wardrik.Agent.Activity
  alias Wardrik.Agent.Activity.English
  alias Wardrik.Agent.Activity.Presenter
  alias Wardrik.Bus

  defp call(name),
    do: %Bus.ToolStarted{
      call_id: name,
      name: name,
      arguments: %{},
      idempotency_key: name,
      decided_by: nil
    }

  defp parked(names), do: %Bus.TurnParked{calls: Enum.map(names, &{%{id: &1, name: &1}, "Go?"})}

  test "says what an agent is doing in a few words" do
    for {doing, pending, label} <- [
          {:idle, 0, "idle"},
          {:idle, 1, "1 message waiting"},
          {:idle, 3, "3 messages waiting"},
          {%Bus.TurnStarted{messages: []}, 0, "thinking"},
          {%Bus.ModelStarted{message_id: "m0", model_spec: "x:y", decided_by: nil}, 0,
           "thinking"},
          {%Bus.ModelRetrying{
             message_id: "m0",
             attempt: 2,
             attempts: 6,
             wait_ms: 0,
             reason: nil
           }, 0, "retrying the model, 2 of 6"},
          {[call("web_search")], 0, "running web_search"},
          {[call("web_search"), call("fetch_page")], 0, "running web_search and fetch_page"},
          {[call("a"), call("b"), call("c")], 0, "running a, b and c"},
          {%Bus.SpanStarted{name: "compacting history"}, 0, "compacting history"},
          {parked(["send_email"]), 0, "waiting on a person to approve send_email"},
          {parked(["model"]), 0, "waiting on a person to approve a model call"},
          {%Bus.ToolDenied{call_id: "c", name: "rm", reason: "no", decided_by: nil}, 0,
           "thinking"},
          {[call("web_search")], 1, "running web_search, 1 message waiting"}
        ] do
      activity = %Activity{doing: doing, since: 0, pending: pending}
      assert Presenter.label(%English{}, activity) == label
    end
  end
end
