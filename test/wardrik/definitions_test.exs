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

      assert refused(scope, "agent.define", Map.put(base, "max_iterations", "infinity")) ==
               :not_supported

      assert refused(scope, "agent.define", Map.put(base, "notify", "ops")) == :invalid_request

      assert refused(scope, "agent.define", Map.put(base, "channels", ["slack"])) ==
               :invalid_request

      from_file = [%{"every" => "30m", "prompt_file" => "HEARTBEAT.md"}]

      assert refused(scope, "agent.define", Map.put(base, "triggers", from_file)) ==
               :invalid_request

      for trigger <- [
            %{"every" => "30m", "prompt_file" => "/etc/passwd"},
            %{"every" => "30m", "prompt_file" => "H.md", "prompt" => "Go."}
          ] do
        assert refused(
                 scope,
                 "agent.define",
                 Map.merge(base, %{"tools" => ["files"], "triggers" => [trigger]})
               ) == :invalid_request
      end

      unread = [%{"every" => "often", "prompt" => "Go."}]
      assert refused(scope, "agent.define", Map.put(base, "triggers", unread)) == :invalid_request

      assert refused(scope, "agent.definition", %{"agent" => "acme/triage"}) == :not_found
    end

    @tag mcp: [{"down", [transport: {:stdio, command: "no-such-mcp-server"}]}]
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
      definition =
        Definition.new!(
          model: @model,
          tools: ["github/*"],
          idle_timeout: :infinity,
          policy: [ask: ["github/*"], budget: [usd: 5, per: :day]]
        )

      assert %Definition{
               model: @model,
               tools: ["github/*"],
               idle_timeout: :infinity,
               policy: %{"ask" => ["github/*"], "budget" => %{"usd" => 5, "per" => "day"}}
             } = definition

      assert Definition.to_json(definition) == %{
               "model" => @model,
               "tools" => ["github/*"],
               "idle_timeout" => "infinity",
               "policy" => %{"ask" => ["github/*"], "budget" => %{"usd" => 5, "per" => "day"}}
             }

      assert_raise ArgumentError, fn -> Definition.new!(model: @model, colour: "blue") end
    end
  end

  describe "in Elixir" do
    test "defines, reads and decides with structs", %{scope: scope} do
      answers([
        calling([call("call_1", "echo", %{}), call("call_2", "echo", %{})]),
        answer("Done.")
      ])

      definition = Definition.new!(model: @model, tools: ["tools"], policy: "careful")

      assert {:ok, %Wardrik.Agent{id: "acme/triage", status: :idle}} =
               Wardrik.Agent.define(scope, "acme/triage", definition)

      assert {:ok, ^definition, []} = Wardrik.Agent.definition(scope, "acme/triage")

      Wardrik.Agent.ask(scope, "acme/triage", "Echo twice")
      until("wardrik.run.interrupted")

      assert {:ok, [%Wardrik.Interrupt{agent_id: "acme/triage"}, %Wardrik.Interrupt{}]} =
               Wardrik.Interrupts.list(scope)

      assert {:ok,
              [%Wardrik.Decision{decision: :approved}, %Wardrik.Decision{decision: :rejected}]} =
               Wardrik.Agent.decide(scope, "acme/triage", %{
                 "call_1" => {:approve, "Go."},
                 "call_2" => {:deny, "No."}
               })

      assert %{"data" => %{"resolved_by" => %{"id" => "acme/@maria"}}} =
               until("wardrik.interrupt.resolved")

      until("wardrik.run.completed")

      assert {:ok, %Wardrik.Agent{status: :asleep}} = Wardrik.Agent.stop(scope, "acme/triage")
      until("wardrik.agent.stopped")
      assert {:ok, %Wardrik.Agent{status: :idle}} = Wardrik.Agent.spawn(scope, "acme/triage")
      assert {:ok, []} = Wardrik.Agent.calls(scope, "acme/triage")

      assert {:ok, %Wardrik.Forgotten{forgotten: ["acme/triage"], kept: [], failed: []}} =
               Wardrik.Agents.forget(scope, resources: ["acme/*"])
    end

    test "defines from a keyword list", %{scope: scope} do
      assert {:ok, %Wardrik.Agent{status: :idle}} =
               Wardrik.Agent.define(scope, "acme/triage",
                 model: @model,
                 instructions: "Be brief."
               )

      assert {:ok, []} = Wardrik.Agents.cancel(scope)
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

  describe "defaults" do
    test "gives a definition what the Wardrik's defaults say, where it says nothing", context do
      store = WardrikStore.ETS.new(name: :"defaults store #{context.test}")

      wardrik =
        Wardrik.new(
          name: :"defaults #{context.test}",
          store: store,
          defaults: %{model: @model, idle_timeout: 60}
        )

      start_supervised!({WardrikStore, store}, id: :defaults_store)

      assert {:ok, opts} =
               Definition.resolve(wardrik, "acme/worker", %{"instructions" => "Work."})

      assert opts[:model] == @model
      assert Definition.idle_timeout(wardrik, %{}) == 60_000
      assert Definition.idle_timeout(wardrik, %{"idle_timeout" => 5}) == 5_000
    end
  end

  describe "conversations" do
    test "runs one on its agent's definition, with a history of its own", %{
      wardrik: wardrik,
      scope: scope
    } do
      answers([answer("Hello.")])
      define(scope, "acme/triage", %{"model" => @model, "instructions" => "Be brief."})

      run!(scope, "agent.ask", %{"agent" => "acme/triage/C1-1696.1234", "content" => "Hi"})
      assert_receive {:prompted, messages}
      assert system(messages) == "Be brief."
      until("wardrik.run.completed")

      conversation = WardrikCore.whereis(Wardrik.agents(wardrik), "acme/triage/C1-1696.1234")
      assert [_asked, _answered] = WardrikCore.history(conversation)

      assert WardrikCore.history(WardrikCore.whereis(Wardrik.agents(wardrik), "acme/triage")) ==
               []

      assert %{"agent" => %{"id" => "acme/triage/C1-1696.1234", "name" => "triage"}} =
               run!(scope, "agent.read", %{"agent" => "acme/triage/C1-1696.1234"})
    end

    test "has no definition or triggers of its own", %{scope: scope} do
      define(scope, "acme/triage", %{"model" => @model})
      conversation = "acme/triage/C1-1696.1234"

      assert refused(scope, "agent.define", %{"agent" => conversation, "model" => @model}) ==
               :invalid_request

      assert refused(scope, "agent.trigger_set", %{
               "agent" => conversation,
               "trigger" => "daily",
               "every" => "1d",
               "prompt" => "Go."
             }) == :invalid_request

      assert refused(scope, "agent.ask", %{"agent" => "acme/other/C1", "content" => "Hi"}) ==
               :not_found
    end

    test "is reached only where a statement covers it", %{wardrik: wardrik, scope: scope} do
      answers([answer("Hello.")])
      define(scope, "acme/triage", %{"model" => @model})
      input = %{"agent" => "acme/triage/C1", "content" => "Hi"}

      agent_only =
        Wardrik.as(wardrik, "acme/@jon", roles: [:messenger], resources: ["acme/agent/triage"])

      assert refused(agent_only, "agent.ask", input) == :not_found

      conversations =
        Wardrik.as(wardrik, "acme/@jon", roles: [:messenger], resources: ["acme/agent/triage/*"])

      run!(conversations, "agent.ask", input)
      until("wardrik.run.completed")
    end

    test "forgets an agent's conversations with it", %{wardrik: wardrik, scope: scope} do
      answers([answer("Hello.")])
      define(scope, "acme/triage", %{"model" => @model})
      run!(scope, "agent.ask", %{"agent" => "acme/triage/C1", "content" => "Hi"})
      until("wardrik.run.completed")

      run!(scope, "agent.forget", %{"agent" => "acme/triage"})

      assert WardrikCore.list(Wardrik.agents(wardrik)) == []
      assert refused(scope, "agent.read", %{"agent" => "acme/triage/C1"}) == :not_found
    end

    @tag idle_timeout: 0.05
    test "sleeps once it has had nothing to do", %{scope: scope} do
      answers([answer("Hello.")])
      define(scope, "acme/triage", %{"model" => @model})
      run!(scope, "agent.ask", %{"agent" => "acme/triage/C1", "content" => "Hi"})

      assert_receive {WardrikEvents, "acme/triage/C1", %{"type" => "wardrik.agent.stopped"}}
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

      assert %{"items" => []} = run!(scope, "agent.timeline", %{"agent" => "acme/triage"})

      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Echo"})
      until("wardrik.run.interrupted")

      assert refused(scope, "agent.clear", %{"agent" => "acme/triage"}) == :conflict
    end
  end

  describe "retries" do
    test "tries a model call that failed again, and says so in the log", %{scope: scope} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:error, %ReqLLM.Error.API.Stream{reason: "Stream failed: :timeout"}}
          _later -> {:ok, answer("Here.")}
        end
      end)

      define(scope, "acme/patient", %{"model" => @model, "retries" => %{"max_wait" => 0}})
      run!(scope, "agent.ask", %{"agent" => "acme/patient", "content" => "Hi"})

      assert %{"data" => %{"attempt" => 1, "attempts" => 6, "error" => %{"type" => "Stream"}}} =
               until("wardrik.message.retrying")

      until("wardrik.run.completed")
    end

    test "waits on a person once the tries are spent, and tries again once they approve", %{
      scope: scope
    } do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:error, %ReqLLM.Error.API.Stream{reason: "Stream failed: :timeout"}}
          _later -> {:ok, answer("Here.")}
        end
      end)

      define(scope, "acme/patient", %{"model" => @model, "retries" => %{"attempts" => 0}})
      run!(scope, "agent.ask", %{"agent" => "acme/patient", "content" => "Hi"})

      assert %{
               "data" => %{
                 "interrupts" => [%{"id" => "model", "reason" => "model_approval"} = asked]
               }
             } =
               until("wardrik.run.interrupted")

      assert asked["message"] =~ "The model failed once"
      run!(scope, "agent.approve", %{"agent" => "acme/patient", "interrupt" => "model"})
      until("wardrik.run.completed")
    end
  end

  describe "compaction" do
    test "summarises an agent's older history as a turn begins", %{scope: scope} do
      answers([answer("Noted."), answer("You sent a long note."), answer("Done.")])

      define(scope, "acme/notes", %{"model" => @model, "compaction" => %{"window" => 20}})

      run!(scope, "agent.ask", %{"agent" => "acme/notes", "content" => String.duplicate("x", 100)})

      until("wardrik.run.completed")

      run!(scope, "agent.ask", %{"agent" => "acme/notes", "content" => "Again."})

      assert %{"data" => %{"messages_before" => 3, "messages_after" => 2}} =
               until("wardrik.conversation.compacted")

      until("wardrik.run.completed")
      assert_receive {:prompted, _first}
      assert_receive {:prompted, _summarising}
      assert_receive {:prompted, messages}

      assert [%{content: [%{text: "A summary of the conversation" <> _rest}]}, %{role: :user}] =
               Enum.reject(messages, &(&1.role == :system))
    end
  end

  describe "triggers" do
    defp trigger_due(wardrik, id, name) do
      store = WardrikStore.scope(wardrik.store, "wardrik_triggers")
      key = "triggers/" <> URI.encode_www_form(id) <> "/" <> name
      {record, _vsn} = WardrikStore.lookup(store, key)
      past = DateTime.utc_now() |> DateTime.add(-5) |> DateTime.to_iso8601()
      {:ok, _vsn} = WardrikStore.put(store, key, %{record | "next_at" => past})
      :ok = WardrikTriggers.reconcile(Wardrik.triggers(wardrik))
    end

    test "gives a defined agent its triggers, and asks it when one comes due, asleep or not", %{
      wardrik: wardrik,
      scope: scope
    } do
      answers([answer("Today's update.")])

      define(scope, "acme/digest", %{
        "model" => @model,
        "triggers" => [%{"every" => "0 9 * * *", "prompt" => "Write it."}]
      })

      assert [{%WardrikTriggers.Trigger{name: "trigger-1"}, %DateTime{}}] =
               WardrikTriggers.list(Wardrik.triggers(wardrik), "acme/digest")

      run!(scope, "agent.stop", %{"agent" => "acme/digest"})
      until("wardrik.agent.stopped")

      trigger_due(wardrik, "acme/digest", "trigger-1")

      assert %{"data" => %{"trigger" => %{"name" => "trigger-1"}, "status" => "asked"}} =
               until("wardrik.trigger.fired")

      assert_receive {:prompted, messages}
      assert %{role: :user} = List.last(messages)
      until("wardrik.run.completed")
    end

    test "asks an agent with files to follow its prompt_file", %{wardrik: wardrik, scope: scope} do
      answers([answer("Done.")])

      define(scope, "acme/digest", %{
        "model" => @model,
        "tools" => ["files"],
        "triggers" => [
          %{"name" => "heartbeat", "every" => "30m", "prompt_file" => "HEARTBEAT.md"}
        ]
      })

      trigger_due(wardrik, "acme/digest", "heartbeat")

      assert %{"data" => %{"status" => "asked"}} = until("wardrik.trigger.fired")
      assert_receive {:prompted, messages}
      assert %{role: :user, content: [%{text: text}]} = List.last(messages)
      assert text =~ "Read HEARTBEAT.md"
      until("wardrik.run.completed")

      assert refused(scope, "agent.trigger_set", %{
               "agent" => "acme/digest",
               "trigger" => "x",
               "every" => "1d",
               "prompt_file" => "../up.md"
             }) == :invalid_request
    end

    test "sets and removes one, keeping the definition in step", %{wardrik: wardrik, scope: scope} do
      define(scope, "acme/digest", %{"model" => @model})

      assert %{"name" => "daily", "every" => "1d"} =
               run!(scope, "agent.trigger_set", %{
                 "agent" => "acme/digest",
                 "trigger" => "daily",
                 "every" => "1d",
                 "prompt" => "Go."
               })

      assert %{"definition" => %{"triggers" => [%{"name" => "daily"}]}} =
               run!(scope, "agent.definition", %{"agent" => "acme/digest"})

      assert %{"name" => "daily"} =
               run!(scope, "agent.trigger_remove", %{
                 "agent" => "acme/digest",
                 "trigger" => "daily"
               })

      assert WardrikTriggers.list(Wardrik.triggers(wardrik), "acme/digest") == []

      assert refused(scope, "agent.trigger_remove", %{
               "agent" => "acme/digest",
               "trigger" => "daily"
             }) ==
               :not_found

      assert refused(scope, "agent.trigger_set", %{
               "agent" => "acme/other",
               "trigger" => "x",
               "every" => "1d",
               "prompt" => "Go."
             }) ==
               :not_found

      assert refused(scope, "agent.trigger_set", %{
               "agent" => "acme/digest",
               "trigger" => "x",
               "every" => "often",
               "prompt" => "Go."
             }) ==
               :invalid_request

      assert %{"events" => changes} = run!(scope, "audit.list", %{})
      assert "wardrik.trigger.set" in Enum.map(changes, & &1["type"])
      assert "wardrik.trigger.removed" in Enum.map(changes, & &1["type"])
    end

    test "forgets an agent's triggers with it", %{wardrik: wardrik, scope: scope} do
      define(scope, "acme/digest", %{
        "model" => @model,
        "triggers" => [%{"every" => "1d", "prompt" => "Go."}]
      })

      run!(scope, "agent.forget", %{"agent" => "acme/digest"})

      assert WardrikTriggers.list(Wardrik.triggers(wardrik), "acme/digest") == []
    end

    test "turns away a webhook request it can't prove", %{scope: scope} do
      define(scope, "acme/digest", %{
        "model" => @model,
        "triggers" => [
          %{"name" => "issues", "webhook" => %{"secret" => "${HOOK}"}, "prompt" => "Triage it."}
        ]
      })

      request = %{
        "agent" => "acme/digest",
        "trigger" => "issues",
        "body" => "{}",
        "headers" => %{}
      }

      assert refused(scope, "hook.deliver", request) == :not_found

      assert refused(scope, "hook.deliver_with_secret", Map.put(request, "secret", "nope")) ==
               :not_found

      assert refused(scope, "hook.deliver", %{request | "trigger" => "missing"}) == :not_found
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
