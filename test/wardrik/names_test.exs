defmodule Wardrik.NamesTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID

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

  test "builds a definition the protocol reads, and refuses one it doesn't" do
    assert %Wardrik.Definition{model: "m", tools: ["files"]} =
             Wardrik.Definition.new!(model: "m", tools: ["files"])

    assert_raise ArgumentError, fn -> Wardrik.Definition.new!(model: 3) end

    named = Wardrik.Definition.named(%{"triggers" => [%{"every" => "1h"}, %{"name" => "own"}]})
    assert [%{"name" => "trigger-1"}, %{"name" => "own"}] = named["triggers"]
    assert Wardrik.Definition.named(%{"model" => "m"}) == %{"model" => "m"}
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
