defmodule Wardrik.TypesTest do
  use ExUnit.Case, async: true

  alias Wardrik.Channel.Installation
  alias Wardrik.Channel.Notification

  test "keeps an installation's token out of what it shows" do
    installation = %Installation{
      channel: "slack",
      workspace: "T0123",
      owner: "acme",
      token: "xoxb-1"
    }

    refute inspect(installation) =~ "xoxb-1"
    assert inspect(installation) =~ "T0123"
  end

  test "names the workspace a notification posts in, and nothing of approvers" do
    notice = %Wardrik.Notice{agent: "acme/triage", kind: :finished, at: ~U[2026-11-01 00:00:00Z]}
    notification = %Notification{workspace: "T0123", room: "#ops", notice: notice}

    assert notification.workspace == "T0123"
    refute Map.has_key?(notification, :approvers)

    refute Map.has_key?(
             %Installation{channel: "c", workspace: "w", owner: "o", token: "t"},
             :approvers
           )
  end

  test "reads an interrupt with the arguments of the call a person decides on" do
    interrupt =
      Wardrik.Interrupt.from_json(%{
        "id" => "call_1",
        "reason" => "tool_approval",
        "message" => "claude/execute needs your approval.",
        "tool_call_id" => "call_1",
        "name" => "claude__execute",
        "arguments" => %{"command" => "mix test"}
      })

    assert %Wardrik.Interrupt{name: "claude__execute", arguments: %{"command" => "mix test"}} =
             interrupt
  end

  test "reads a notice as the JSON a webhook receives" do
    interrupt = %Wardrik.Interrupt{
      id: "int_1",
      tool_call_id: "call_1",
      name: "echo",
      message: "Go?"
    }

    notice = %Wardrik.Notice{
      agent: "acme/triage",
      kind: :parked,
      at: ~U[2026-11-01 00:00:00Z],
      calls: [%{interrupt: interrupt, arguments: %{"text" => "hi"}}]
    }

    assert Wardrik.Notice.kinds() == [:parked, :failed, :finished]

    assert %{
             "event" => "turn_parked",
             "agent" => "acme/triage",
             "at" => "2026-11-01T00:00:00Z",
             "calls" => [
               %{
                 "id" => "call_1",
                 "name" => "echo",
                 "arguments" => %{"text" => "hi"},
                 "prompt" => "Go?",
                 "authorization" => false,
                 "labels" => []
               }
             ]
           } = Wardrik.Notice.json(notice)
  end

  test "reads a reply's text from the assistant's messages" do
    messages = [
      %{"role" => "user", "parts" => [%{"type" => "text", "content" => "Hi"}]},
      %{"role" => "assistant", "parts" => [%{"type" => "text", "content" => "Hello"}]},
      %{
        "role" => "assistant",
        "parts" => [%{"type" => "tool_call"}, %{"type" => "text", "content" => "."}]
      }
    ]

    assert Wardrik.Reply.text(messages) == "Hello."
  end

  test "gives an error as the protocol's JSON body" do
    error = Wardrik.Error.new(:not_found, "No agent acme/triage.")

    assert Wardrik.Error.json(error) ==
             %{"error" => %{"type" => "not_found", "message" => "No agent acme/triage."}}
  end
end
