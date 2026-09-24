defmodule TarsNotify.NoticeTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Tars.Event
  alias TarsNotify.Notice

  defp event(payload) do
    %Event{source: %{agent_id: "acme/_/triage"}, payload: payload, at: 1_790_000_000_000_000}
  end

  test "a parked turn names each call and its question" do
    call = %{id: "call_1", name: "deploy", arguments: %{"env" => "prod"}}

    assert {:ok, %Notice{kind: :parked, agent: "acme/_/triage", calls: [parked]} = notice} =
             Notice.from_event(event({:turn_parked, [{call, "This ships to production."}]}))

    assert parked == %{
             id: "call_1",
             name: "deploy",
             arguments: %{"env" => "prod"},
             prompt: "This ships to production."
           }

    assert notice.at == DateTime.from_unix!(1_790_000_000_000_000, :microsecond)
  end

  test "a failed turn keeps its reason, and a finished one what it said last" do
    assert {:ok, %Notice{kind: :failed, reason: :timeout}} =
             Notice.from_event(event({:turn_failed, :timeout}))

    messages = [Context.assistant("Looking."), Context.assistant("Two incidents need you.")]

    assert {:ok, %Notice{kind: :finished, text: "Two incidents need you."}} =
             Notice.from_event(event({:turn_finished, messages}))
  end

  test "any other event is nobody's business" do
    assert Notice.from_event(event({:turn_started, ["hi"]})) == :none
  end

  test "to_map/1 is what a webhook sends" do
    {:ok, notice} = Notice.from_event(event({:turn_failed, :timeout}))

    assert %{event: "turn_failed", agent: "acme/_/triage", reason: ":timeout", calls: []} =
             Notice.to_map(notice)
  end
end
