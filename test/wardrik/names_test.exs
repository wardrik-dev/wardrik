defmodule Wardrik.NamesTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Channel.Installation
  alias Wardrik.Resource

  test "reads an agent's ID, a person's agent's, and a conversation of either" do
    assert {:ok, %AgentID{owner: "acme", name: "triage", conversation: nil}} =
             AgentID.parse("acme/triage")

    assert {:ok, %AgentID{owner: "acme/@jon", name: "triage", conversation: "C1-1696.1234"}} =
             AgentID.parse("acme/@jon/triage/C1-1696.1234")

    assert AgentID.agent("acme/@jon/triage/C1-1696.1234") == "acme/@jon/triage"
    assert AgentID.conversation?("acme/triage/C1-1.1")
    refute AgentID.conversation?("acme/triage")
  end

  test "refuses a segment that holds what names a person known elsewhere, or a pattern" do
    for id <- [
          "slack:T0123/U024BE7LH",
          "acme/tri:age",
          "acme/@sl:ack/triage",
          "acme/*",
          "acme/tri?"
        ] do
      assert AgentID.parse(id) == :error, id
    end
  end

  test "reads an agent's owner as an owner, so only the owner holds a person" do
    for id <- [
          "acme/@jon",
          "ac@me/triage",
          "acme/@j@n/triage",
          "acme/@/triage",
          "/triage",
          "acme/@jon/triage/C1/2"
        ] do
      assert AgentID.parse(id) == :error, id
    end

    assert {:ok, %AgentID{owner: "acme", name: "triage", conversation: "@C1"}} =
             AgentID.parse("acme/triage/@C1")
  end

  test "names the deployment as an owner" do
    assert Resource.deployment() == "deployment"
  end

  test "knows which agents are an installation owner's own" do
    installation = %Installation{
      channel: "slack",
      workspace: "T0123",
      owner: "acme",
      token: "xoxb"
    }

    assert Installation.owns?(installation, "acme/triage")
    assert Installation.owns?(installation, "acme/triage/C1-1.1")
    refute Installation.owns?(installation, "acme/@jon/notes")
    refute Installation.owns?(installation, "beta/triage")
    refute Installation.owns?(installation, "acme")
  end

  test "writes an error as the protocol's error body, and raises it saying why" do
    error = Wardrik.Error.new(:not_found, "There's no agent x.")
    assert_raise Wardrik.Error, "There's no agent x.", fn -> raise error end

    assert Wardrik.Error.json(error) == %{
             "error" => %{"type" => "not_found", "message" => "There's no agent x."}
           }
  end

  test "writes a notice as a webhook is sent it" do
    interrupt = %Wardrik.Interrupt{id: "c1", name: "publish", reason: :tool_approval}

    notice = %Wardrik.Notice{
      agent: "acme/triage",
      kind: :parked,
      at: ~U[2026-10-28 12:00:00Z],
      calls: [%{interrupt: interrupt, arguments: %{"to" => "all"}}]
    }

    assert %{"event" => "turn_parked", "agent" => "acme/triage", "calls" => [call]} =
             Wardrik.Notice.json(notice)

    assert call["name"] == "publish"
    assert :parked in Wardrik.Notice.kinds()
  end

  test "reads what the assistant said in a run's messages" do
    messages = [
      %{"role" => "user", "parts" => [%{"type" => "text", "content" => "Hi"}]},
      %{"role" => "assistant", "parts" => [%{"type" => "text", "content" => "Hello."}]}
    ]

    assert Wardrik.Reply.text(messages) == "Hello."
  end

  test "builds a definition the protocol reads, and refuses one it doesn't" do
    assert %Wardrik.Definition{model: "m", tools: ["files"]} =
             Wardrik.Definition.new!(model: "m", tools: ["files"])

    assert_raise ArgumentError, fn -> Wardrik.Definition.new!(model: 3) end

    named = Wardrik.Definition.named(%{"triggers" => [%{"every" => "1h"}, %{"name" => "own"}]})
    assert [%{"name" => "trigger-1"}, %{"name" => "own"}] = named["triggers"]
    assert Wardrik.Definition.named(%{"model" => "m"}) == %{"model" => "m"}

    assert %WardrikCore.Principal{id: "acme/@jon"} =
             Wardrik.Definition.principal("acme/@jon/triage")
  end

  test "names what a path takes: the text given, or the struct's id or name" do
    types = Wardrik.Operations.Types

    for {struct, name} <- [
          {%Wardrik.Agent{id: "acme/triage"}, "acme/triage"},
          {%Wardrik.Interrupt{id: "c1"}, "c1"},
          {%Wardrik.Call{id: "call_1"}, "call_1"},
          {%Wardrik.Trigger{name: "weekly"}, "weekly"}
        ] do
      assert types.path(struct) == name
    end

    assert types.path("acme/triage") == "acme/triage"
  end
end
