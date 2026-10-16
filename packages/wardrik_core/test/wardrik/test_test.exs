defmodule Wardrik.TestTest do
  use ExUnit.Case, async: true

  alias Wardrik.Call
  alias Wardrik.Test.Tools

  describe "scope/1" do
    test "is built for an agent of the test's own, with what a turn is given" do
      scope = Wardrik.Test.scope(tools: [Wardrik.Test.EchoTool])

      assert to_string(scope.source.agent_id) =~ ~r"^test/agent-\d+$"
      assert ["echo"] = Enum.map(Wardrik.LLM.Config.tools(scope.config), & &1.name)
    end

    test "takes an ID, or the whole config, instead" do
      config = Wardrik.LLM.Config.new(tools: [Tools.Deploy], system: "Be brief.")
      id = Wardrik.AgentID.parse!("acme/@jon/assistant")
      scope = Wardrik.Test.scope(config: config, id: id)

      assert scope.source.agent_id == id
      assert scope.config.system == "Be brief."
    end
  end

  describe "call/4" do
    test "runs a call through the steps a turn runs it, and hands back how it came out" do
      scope = Wardrik.Test.scope(tools: [Wardrik.Test.EchoTool])

      assert %Call{id: "call_9", state: :done, result: {:ok, %{value: "hi"}}} =
               Wardrik.Test.call(scope, "echo", %{"value" => "hi"}, id: "call_9")
    end

    test "a gated call waits on a person, and runs on once they approve" do
      scope = Wardrik.Test.scope(tools: [Tools.Deploy])
      waiting = Wardrik.Test.call(scope, "deploy", %{"target" => "prod"})

      assert %Call{state: :waiting} = waiting
      assert Call.prompt(waiting) =~ "gated"

      assert %Call{state: :done, result: {:ok, %{"deployed" => "prod"}}} =
               Wardrik.Test.resume(scope, waiting)
    end

    test "check/3 says what the hooks make of a call, declared, and runs nothing" do
      hooks = [Wardrik.Hook.new("rules", Tools.Rules, deny: ["deploy"])]
      scope = Wardrik.Test.scope(tools: [Tools.Deploy], hooks: hooks)

      assert %Call{state: :denied, target: %Call.Tool{gated: true, subjects: ["prod"]}} =
               Wardrik.Test.check(scope, "deploy", %{"target" => "prod"})
    end

    test "the scope's hooks decide the call" do
      hooks = [Wardrik.Hook.new("rules", Tools.Rules, allow: ["deploy"])]
      scope = Wardrik.Test.scope(tools: [Tools.Deploy], hooks: hooks)

      assert %Call{state: :done, result: {:ok, _deployed}} =
               Wardrik.Test.call(scope, "deploy", %{"target" => "prod"})
    end
  end
end
