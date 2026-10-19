defmodule WardrikNotify.NoticeTest do
  use ExUnit.Case, async: true

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Script
  alias WardrikNotify.Notice

  @time "2026-10-19T12:04:09.611000Z"

  defp entry(type, data, agent \\ ~A"acme/triage"),
    do: %Entry{log: agent, event: %{"type" => type, "time" => @time, "data" => data}, follows: 0}

  defp from(entry), do: Notice.from_entry(entry, host: Wardrik.Test.host())

  # An agent waiting on the call "call_1", and the entry of its log for the
  # turn that parked.
  defp parked do
    config = Script.new({AgentRunners, :parking, [self(), "call_1"]})
    {agent, pid} = Wardrik.Test.Fleet.start_agent(config: config)
    :ok = Log.subscribe(agent)
    :ok = Wardrik.Agent.ask(pid, "Ship it.")
    assert_receive %Entry{event: %{"type" => "wardrik.run.interrupted"}} = entry, 5_000
    {agent, entry}
  end

  test "a parked turn names each call it still waits on, and its question, as it was written" do
    {agent, entry} = parked()

    assert {:ok, %Notice{kind: :parked, agent: ^agent, calls: [call]} = notice} = from(entry)
    assert %{id: "call_1", prompt: "This ships to production.", authorization: false} = call
    assert {:ok, notice.at, 0} == DateTime.from_iso8601(entry.event["time"])

    elsewhere = put_in(entry.event["data"]["interrupts"], [%{"id" => "call_2"}])
    assert from(elsewhere) == :none
    assert from(%{entry | log: ~A"acme/nobody-waits"}) == :none
  end

  test "the calls an agent waits on, as it answers them, make a notice of now" do
    call = %{id: "call_1", name: "deploy", arguments: %{"env" => "prod"}, labels: ["outside"]}
    before = DateTime.utc_now()

    assert %Notice{kind: :parked, agent: ~A"acme/triage", calls: [parked], at: at} =
             Notice.parked(~A"acme/triage", [{call, "This ships to production."}])

    assert parked == %{
             id: "call_1",
             name: "deploy",
             arguments: %{"env" => "prod"},
             prompt: "This ships to production.",
             authorization: false,
             labels: ["outside"]
           }

    assert DateTime.compare(at, before) != :lt
  end

  test "a call waiting on an authorization is named without its link" do
    call = %{
      id: "call_1",
      name: "github__issues",
      arguments: %{},
      link: %{url: "https://github.com/login/device", code: "WDJB-MJHT"}
    }

    notice = Notice.parked(~A"acme/triage", [{call, "To connect github, open its link."}])
    assert [%{authorization: true}] = notice.calls

    encoded = notice |> Notice.to_map() |> JSON.encode!()
    refute encoded =~ "WDJB-MJHT"
    refute encoded =~ "github.com/login"
  end

  test "a failed turn keeps why, and a finished one what it said last" do
    failed =
      entry("wardrik.run.failed", %{
        "error" => %{"type" => "timeout", "message" => "It took too long."}
      })

    assert {:ok, %Notice{kind: :failed, reason: "It took too long."}} = from(failed)

    said = fn text ->
      %{"role" => "assistant", "parts" => [%{"type" => "text", "content" => text}]}
    end

    messages = [said.("Looking."), said.("Two incidents need you."), said.("")]

    assert {:ok, %Notice{kind: :finished, text: "Two incidents need you."}} =
             from(entry("wardrik.run.completed", %{"messages" => messages}))

    assert {:ok, %Notice{text: ""}} = from(entry("wardrik.run.completed", %{"messages" => []}))
  end

  test "any other entry is nobody's business" do
    assert from(entry("wardrik.run.started", %{"run" => %{"id" => "r1"}})) == :none
    assert from(entry("wardrik.events.dropped", %{"after" => 0, "oldest" => 4})) == :none
  end

  test "to_map/1 is what a webhook sends" do
    {:ok, notice} = from(entry("wardrik.run.failed", %{"error" => %{"message" => "Timed out."}}))

    assert %{
             event: "turn_failed",
             agent: "acme/triage",
             at: "2026-10-19T12:04:09.611000Z",
             reason: "Timed out.",
             calls: []
           } = Notice.to_map(notice)
  end

  test "reason_text/1 says what an error says, rather than what it holds" do
    stalled = %Wardrik.LLM.Error{message: "Stream failed: :timeout"}

    assert Notice.reason_text(stalled) == "Stream failed: :timeout"
    assert Notice.reason_text("A person refused this call.") == "A person refused this call."
    assert Notice.reason_text({:policy_denied, "No."}) == ~s({:policy_denied, "No."})
  end
end
