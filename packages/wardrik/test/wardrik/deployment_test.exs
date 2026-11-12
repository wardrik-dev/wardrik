defmodule Wardrik.DeploymentTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"wardrik #{context.test}"},
        name: :"wardrik #{context.test}",
        store: store,
        deployment: "test",
        capabilities: [tools: Wardrik.Test.Tools],
        policies: [careful: [ask: ["echo"]]]
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  test "holds every agent a scope defines to the scope's policy", %{scope: scope} do
    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, calling([call("call_1", "echo", %{})])}
    end)

    ci = %{scope | policy: "careful"}

    {:ok, _agent} = Wardrik.Agent.define(ci, "acme/bot", model: @model, tools: ["tools"])

    assert {:waiting, [%Wardrik.Interrupt{id: "call_1"}]} =
             Wardrik.Agent.reply(ci, "acme/bot", "Echo")
  end

  describe "the deployment" do
    test "lists its nodes, moves an agent, and reads every definition again", %{scope: scope} do
      here = to_string(node())
      {:ok, _agent} = Wardrik.Agent.define(scope, "acme/bot", model: @model)

      assert {:ok,
              %Wardrik.Nodes{
                nodes: [%Wardrik.Node{name: ^here, agents: 1}],
                running: 0,
                idle: 1,
                parked: 0,
                asleep: 0
              }} = Wardrik.Deployment.nodes(scope)

      assert {:ok, %Wardrik.Agent{id: "acme/bot", node: ^here}} =
               Wardrik.Agent.move(scope, "acme/bot", node: here)

      assert {:error, %Wardrik.Error{type: :invalid_request}} =
               Wardrik.Agent.move(scope, "acme/bot", node: "nowhere@nohost")

      assert {:error, %Wardrik.Error{type: :not_found}} =
               Wardrik.Agent.move(scope, "acme/none", node: here)

      assert {:ok, %Wardrik.Agent{node: ^here}} = Wardrik.Agent.read(scope, "acme/bot")
      assert {:ok, [^here]} = Wardrik.Deployment.reload(scope)

      {:ok, %Wardrik.Agent{node: nil}} = Wardrik.Agent.stop(scope, "acme/bot")
    end

    test "brings only the agents it names to their definitions, where it names them", %{
      wardrik: wardrik,
      scope: scope
    } do
      test = self()

      stub(ReqLLM, :stream_text, fn _model, [system | _messages], _opts ->
        %ReqLLM.Message{role: :system, content: [part | _rest]} = system
        send(test, {:instructions, part.text})
        {:ok, answer("Done.")}
      end)

      for id <- ["acme/a", "acme/b"] do
        {:ok, _agent} = Wardrik.Agent.define(scope, id, model: @model, instructions: "Old.")

        :ok =
          Wardrik.Definitions.put(wardrik, id, %{"model" => @model, "instructions" => "New."})
      end

      assert {:ok, _nodes} = Wardrik.Deployment.reload(scope, agents: ["acme/a"])

      {:ok, _reply} = Wardrik.Agent.reply(scope, "acme/a", "Go")
      assert_receive {:instructions, "New."}

      {:ok, _reply} = Wardrik.Agent.reply(scope, "acme/b", "Go")
      assert_receive {:instructions, "Old."}
    end

    test "reads resource use for each node and each running agent", %{scope: scope} do
      here = to_string(node())
      {:ok, _agent} = Wardrik.Agent.define(scope, "acme/bot", model: @model)

      assert %{"nodes" => [node], "agents" => [agent]} =
               run!(scope, "deployment.runtime", %{})

      assert %{"name" => ^here, "agents" => 1, "memory" => %{"total" => total}} = node
      assert total > 0
      assert node["scheduler_utilization"] >= 0 and node["scheduler_utilization"] <= 1
      assert node["processes"]["count"] < node["processes"]["limit"]
      assert node["memory"]["persistent_term"] > 0

      if File.exists?("/proc/self/status"), do: assert(node["memory"]["resident"] > total)

      groups = node["process_groups"]
      assert Enum.sum_by(groups, & &1["processes"]) > 0

      assert %{"application" => "wardrik_core", "processes" => 1} =
               Enum.find(groups, &(&1["module"] == "WardrikCore.Agent"))

      assert Enum.find(groups, &(&1["module"] == ":application_controller"))

      assert %{"application" => "kernel"} =
               Enum.find(groups, &(&1["module"] == ":code_server"))

      assert %{"agent" => "acme/bot", "node" => ^here, "processes" => 1} = agent
      assert agent["memory_bytes"] > 0

      assert %{"agents" => []} = run!(scope, "deployment.runtime", %{"limit" => 0})

      assert {:ok, %Wardrik.AgentRuntime{agent: "acme/bot", node: ^here, message_queue: 0}} =
               Wardrik.Agent.runtime(scope, "acme/bot")

      {:ok, _agent} = Wardrik.Agent.stop(scope, "acme/bot")

      assert %{"nodes" => [%{"agents" => 0}], "agents" => []} =
               run!(scope, "deployment.runtime", %{})

      assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Agent.runtime(scope, "acme/bot")
    end
  end
end
