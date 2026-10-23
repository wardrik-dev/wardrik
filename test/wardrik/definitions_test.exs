defmodule Wardrik.DefinitionsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Definition

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global

  setup context do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        capabilities: [tools: Wardrik.Test.Tools, block: {Wardrik.Test.Blocking, self()}],
        policies: [careful: [ask: ["echo"]]],
        middleware: [{Wardrik.Test.Tell, self()}],
        mcp: Map.get(context, :mcp),
        idle_timeout: Map.get(context, :idle_timeout, 900)
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    stub(ReqLLM, :stream_text, fn _model, messages, _opts ->
      send(self_test(), {:prompted, messages})
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  defp self_test, do: Process.whereis(:definitions_test)

  defp define(scope, id, definition),
    do: run!(scope, "agent.define", Map.put(definition, "agent", id))

  defp system(messages) do
    assert [%{role: :system, content: [%{text: text}]} | _rest] = messages
    text
  end

  setup do
    Process.register(self(), :definitions_test)
    :ok
  end

  describe "defining" do
    test "starts the agent, and keeps its definition", %{scope: scope} do
      answers([answer("Nothing.")])
      definition = %{"model" => @model, "instructions" => "Be brief.", "tools" => ["tools"]}

      assert %{"status" => "idle"} = define(scope, "acme/triage", definition)

      assert %{"definition" => ^definition, "missing" => []} =
               run!(scope, "agent.definition", %{"agent" => "acme/triage"})

      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Hi"})
      assert_receive {:prompted, messages}
      assert system(messages) == "Be brief."
      until("wardrik.run.completed")
    end

    test "brings a running agent to its new definition from its next turn", %{scope: scope} do
      answers([answer("One."), answer("Two.")])
      define(scope, "acme/triage", %{"model" => @model, "instructions" => "Be brief."})
      define(scope, "acme/triage", %{"model" => @model, "instructions" => "Be kind."})

      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Hi"})
      assert_receive {:prompted, messages}
      assert system(messages) == "Be kind."
    end

    test "holds the agent to the policy it names", %{scope: scope} do
      answers([calling([call("call_1", "echo", %{"text" => "hi"})]), answer("Done.")])

      define(scope, "acme/triage", %{
        "model" => @model,
        "tools" => ["tools"],
        "policy" => "careful"
      })

      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Echo hi"})
      until("wardrik.run.interrupted")

      assert %{"status" => "parked", "interrupts" => [%{"id" => "call_1"}]} =
               run!(scope, "agent.read", %{"agent" => "acme/triage"})
    end

    test "refuses what it doesn't know, or doesn't support yet", %{scope: scope} do
      base = %{"agent" => "acme/triage", "model" => @model}

      assert refused(scope, "agent.define", Map.put(base, "tools", ["nope"])) == :invalid_request
      assert refused(scope, "agent.define", Map.put(base, "policy", "lax")) == :invalid_request

      assert refused(scope, "agent.define", Map.put(base, "policy", %{"maybe" => []})) ==
               :invalid_request

      assert refused(scope, "agent.define", Map.put(base, "model", "nope:nope")) ==
               :invalid_request

      assert refused(scope, "agent.define", Map.delete(base, "model")) == :invalid_request
      assert refused(scope, "agent.define", Map.put(base, "tools", ["self/*"])) == :not_supported

      assert refused(scope, "agent.define", Map.put(base, "max_iterations", "infinity")) ==
               :not_supported

      trigger = [%{"name" => "daily", "every" => "0 9 * * *", "prompt" => "Go."}]
      assert refused(scope, "agent.define", Map.put(base, "triggers", trigger)) == :not_supported

      assert refused(scope, "agent.definition", %{"agent" => "acme/triage"}) == :not_found
    end

    @tag mcp: [down: [transport: {:stdio, command: "no-such-mcp-server"}]]
    test "gives every tool and server for *, and says which offer nothing yet", %{scope: scope} do
      answers([answer("Hi.")])
      define(scope, "acme/@maria/notes", %{"model" => @model, "tools" => ["*"], "timeout" => 60})

      assert %{"missing" => ["down/*"]} =
               run!(scope, "agent.definition", %{"agent" => "acme/@maria/notes"})

      run!(scope, "agent.ask", %{"agent" => "acme/@maria/notes", "content" => "Hi"})
      assert_receive {:middleware, "acme/@maria/notes"}
      until("wardrik.run.completed")
    end

    test "builds a definition in Elixir" do
      assert %{
               "model" => @model,
               "tools" => ["github/*"],
               "idle_timeout" => "infinity",
               "policy" => %{"ask" => ["github/*"], "budget" => %{"usd" => 5, "per" => "day"}}
             } =
               Definition.new!(
                 model: @model,
                 tools: ["github/*"],
                 idle_timeout: :infinity,
                 policy: [ask: ["github/*"], budget: [usd: 5, per: :day]]
               )

      assert_raise ArgumentError, fn -> Definition.new!(model: @model, colour: "blue") end
    end
  end

  describe "sleeping" do
    test "stops an agent, and wakes it when it's asked", %{scope: scope} do
      answers([answer("Awake.")])
      define(scope, "acme/triage", %{"model" => @model})

      assert %{"agent" => %{"status" => "asleep"}} =
               run!(scope, "agent.stop", %{"agent" => "acme/triage"})

      until("wardrik.agent.stopped")

      assert %{"status" => "asleep"} = run!(scope, "agent.read", %{"agent" => "acme/triage"})
      assert %{"agents" => [%{"status" => "asleep"}]} = run!(scope, "agents.list", %{})
      assert refused(scope, "agent.calls", %{"agent" => "acme/triage"}) == :not_found

      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Hi"})
      until("wardrik.run.completed")

      assert %{"status" => "idle"} = run!(scope, "agent.read", %{"agent" => "acme/triage"})
    end

    test "starts an agent that sleeps", %{scope: scope} do
      define(scope, "acme/triage", %{"model" => @model})
      run!(scope, "agent.stop", %{"agent" => "acme/triage"})
      until("wardrik.agent.stopped")

      assert %{"agent" => %{"status" => "idle"}} =
               run!(scope, "agent.spawn", %{"agent" => "acme/triage"})
    end

    @tag idle_timeout: 0.05
    test "puts an agent to sleep once it has had nothing to do", %{scope: scope} do
      define(scope, "acme/triage", %{"model" => @model})

      until("wardrik.agent.stopped")
      assert %{"status" => "asleep"} = run!(scope, "agent.read", %{"agent" => "acme/triage"})
    end
  end

  describe "forgetting and clearing" do
    test "forgets an agent, and records who did", %{scope: scope} do
      define(scope, "acme/triage", %{"model" => @model})

      assert run!(scope, "agent.forget", %{"agent" => "acme/triage"}) == nil

      assert refused(scope, "agent.read", %{"agent" => "acme/triage"}) == :not_found
      assert refused(scope, "agent.forget", %{"agent" => "acme/triage"}) == :not_found

      assert %{"events" => changes} = run!(scope, "audit.list", %{})

      assert ["wardrik.agent.defined", "wardrik.agent.forgotten"] =
               Enum.map(changes, & &1["type"])

      assert %{"data" => %{"actor" => %{"id" => "acme/@maria"}}} = List.last(changes)
    end

    test "empties a conversation, but not while it waits on a person", %{
      wardrik: wardrik,
      scope: scope
    } do
      answers([answer("Hello."), calling([call("call_1", "echo", %{})]), answer("Done.")])

      define(scope, "acme/triage", %{
        "model" => @model,
        "tools" => ["tools"],
        "policy" => "careful"
      })

      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Hi"})
      until("wardrik.run.completed")

      assert %{"status" => "idle"} = run!(scope, "agent.clear", %{"agent" => "acme/triage"})

      pid = WardrikCore.whereis(Wardrik.agents(wardrik), "acme/triage")
      assert WardrikCore.history(pid) == []

      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Echo"})
      until("wardrik.run.interrupted")

      assert refused(scope, "agent.clear", %{"agent" => "acme/triage"}) == :conflict
    end
  end

  describe "calls" do
    setup %{scope: scope} do
      answers([calling([call("call_1", "block", %{})]), answer("Done.")])
      define(scope, "acme/triage", %{"model" => @model, "tools" => ["block"]})
      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Block"})
      assert_receive {:running, "call_1", tool}, 1000
      until("wardrik.tool_call.started")
      %{tool: tool}
    end

    test "lists the calls an agent runs, and stops one", %{scope: scope, tool: tool} do
      assert %{"calls" => [%{"id" => "call_1", "name" => "block", "elapsed_ms" => elapsed}]} =
               run!(scope, "agent.calls", %{"agent" => "acme/triage"})

      assert elapsed >= 0

      ref = Process.monitor(tool)
      assert run!(scope, "agent.kill", %{"agent" => "acme/triage", "call" => "call_1"}) == nil
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}

      assert %{"data" => %{"status" => "error"}} = until("wardrik.tool_call.completed")
      until("wardrik.run.completed")

      assert refused(scope, "agent.kill", %{"agent" => "acme/triage", "call" => "call_1"}) ==
               :not_found
    end

    test "cancels and forgets every agent the patterns cover", %{scope: scope} do
      assert %{"cancelled" => ["acme/triage"]} =
               run!(scope, "agents.cancel", %{"resources" => ["acme/*"]})

      until("wardrik.run.cancelled")

      assert %{"forgotten" => ["acme/triage"], "kept" => [], "failed" => []} =
               run!(scope, "agents.forget", %{"resources" => ["acme/*"]})

      assert %{"agents" => []} = run!(scope, "agents.list", %{})
    end
  end
end
