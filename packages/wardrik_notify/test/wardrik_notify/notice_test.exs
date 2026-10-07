defmodule WardrikNotify.NoticeTest do
  use ExUnit.Case, async: true

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias ReqLLM.Context
  alias Wardrik.Event
  alias WardrikNotify.Notice

  defp event(payload) do
    %Event{source: %{agent_id: ~A"acme/triage"}, payload: payload, at: 1_790_000_000_000_000}
  end

  test "a parked turn names each call and its question" do
    call = %{id: "call_1", name: "deploy", arguments: %{"env" => "prod"}}

    assert {:ok, %Notice{kind: :parked, agent: ~A"acme/triage", calls: [parked]} = notice} =
             Notice.from_event(event({:turn_parked, [{call, "This ships to production."}]}))

    assert parked == %{
             id: "call_1",
             name: "deploy",
             arguments: %{"env" => "prod"},
             prompt: "This ships to production.",
             authorization: false,
             outside_content: false
           }

    assert notice.at == DateTime.from_unix!(1_790_000_000_000_000, :microsecond)
  end

  test "a call a turn made after reading content from outside says so" do
    call = %{id: "call_1", name: "deploy", arguments: %{}, outside: true}

    assert {:ok, %Notice{calls: [%{outside_content: true}]}} =
             Notice.from_event(event({:turn_parked, [{call, "This ships to production."}]}))
  end

  test "a call waiting on an authorization is named without its link" do
    call = %{
      id: "call_1",
      name: "github__issues",
      arguments: %{},
      link: %{url: "https://github.com/login/device", code: "WDJB-MJHT"}
    }

    assert {:ok, notice} =
             Notice.from_event(
               event({:turn_parked, [{call, "To connect github, open its link."}]})
             )

    assert [%{authorization: true}] = notice.calls

    encoded = notice |> Notice.to_map() |> JSON.encode!()
    refute encoded =~ "WDJB-MJHT"
    refute encoded =~ "github.com/login"
  end

  test "a failed turn keeps its reason, and a finished one what it said last" do
    assert {:ok, %Notice{kind: :failed, reason: :timeout}} =
             Notice.from_event(event({:turn_failed, :timeout}))

    messages = [Context.assistant("Looking."), Context.assistant("Two incidents need you.")]

    assert {:ok, %Notice{kind: :finished, text: "Two incidents need you."}} =
             Notice.from_event(event({:turn_finished, messages}))
  end

  test "any other event is nobody's business" do
    assert Notice.from_event(event({:turn_started, [Wardrik.Agent.Message.new("hi")]})) == :none
  end

  test "to_map/1 is what a webhook sends" do
    {:ok, notice} = Notice.from_event(event({:turn_failed, :timeout}))

    assert %{event: "turn_failed", agent: "acme/triage", reason: ":timeout", calls: []} =
             Notice.to_map(notice)
  end

  test "reason_text/1 says what an error says, rather than what it holds" do
    stalled =
      ReqLLM.Error.API.Stream.exception(reason: "Stream failed: :timeout", cause: :timeout)

    assert Notice.reason_text(stalled) == "Stream failed: :timeout"
    assert Notice.reason_text("A person refused this call.") == "A person refused this call."
    assert Notice.reason_text({:policy_denied, "No."}) == ~s({:policy_denied, "No."})
  end
end
