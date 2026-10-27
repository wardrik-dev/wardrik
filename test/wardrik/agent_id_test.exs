defmodule Wardrik.AgentIDTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias Wardrik.AgentID

  setup :start_wardrik

  test "reads an agent's ID, a person's agent's, and a conversation of either" do
    assert {:ok, %AgentID{owner: "acme", name: "triage", conversation: nil}} =
             AgentID.parse("acme/triage")

    assert {:ok, %AgentID{owner: "acme/@jon", name: "triage", conversation: "C1-1696.1234"}} =
             AgentID.parse("acme/@jon/triage/C1-1696.1234")
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

  test "refuses to define an agent under such an ID", %{wardrik: wardrik} do
    scope = owner(wardrik)
    input = %{"agent" => "acme/tri:age", "model" => "anthropic:claude-haiku-4-5"}

    assert refused(scope, "agent.define", input) == :invalid_request
    assert refused(scope, "secrets.list", %{"owner" => "slack:T0123"}) == :invalid_request
  end
end
