defmodule Wardrik.AnswersTest do
  use ExUnit.Case, async: true

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Testing.Model

  setup :start_wardrik

  setup %{wardrik: wardrik, fake: fake} do
    Model.answer(fake, fn _request ->
      Model.text(["Nothing's ", "on ", "fire."])
    end)

    agent = start_agent(wardrik, "acme/triage")
    %{scope: owner(wardrik), agent: agent}
  end

  test "streams an answer's text as it's written", %{scope: scope} do
    stream = Wardrik.Agent.stream(scope, "acme/triage", "What's on fire?")

    assert Enum.to_list(stream) == ["Nothing's ", "on ", "fire."]
  end

  test "takes the agent as a struct", %{scope: scope} do
    {:ok, agent} = Wardrik.Agent.read(scope, "acme/triage")

    assert {:ok, %Wardrik.Reply{text: "Nothing's on fire."}} =
             Wardrik.Agent.reply(scope, agent, "What's on fire?")
  end

  test "sends what an answer brings to a process", %{scope: scope} do
    assert {:ok, ref} = Wardrik.Agent.stream(scope, "acme/triage", "What's on fire?", to: self())

    assert_receive {Wardrik, ^ref, {:text, "Nothing's "}}
    assert_receive {Wardrik, ^ref, {:done, %Wardrik.Reply{text: "Nothing's on fire."}}}
  end

  test "says when the answer waits on a person", %{fake: fake, scope: scope} do
    Model.answer(fake, fn _request -> calling([call("call_1", "echo", %{})]) end)

    assert {:waiting, [%Wardrik.Interrupt{id: "call_1", reason: :tool_approval}]} =
             Wardrik.Agent.reply(scope, "acme/triage", "Echo")
  end

  test "can't reach an agent it isn't allowed to", %{wardrik: wardrik} do
    nobody = build_limited_scope(wardrik, "acme/@nobody", roles: [:reader], owners: [])

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Agent.reply(nobody, "acme/triage", "Hi")

    assert_raise Wardrik.Error, fn ->
      nobody
      |> Wardrik.Agent.stream("acme/triage", "Hi")
      |> Enum.to_list()
    end
  end
end
