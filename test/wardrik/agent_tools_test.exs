defmodule Wardrik.AgentToolsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global

  setup context do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        policies: [relay: [allow_after: %{"outside" => ["agent_ask"]}]]
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{scope: owner(wardrik)}
  end

  # Answers by what the last message says, since two agents' turns run at once.
  defp model(script) do
    {:ok, steps} = Agent.start_link(fn -> script end)
    test = self()

    stub(ReqLLM, :stream_text, fn _model, messages, _opts ->
      said = messages |> List.last() |> text()
      send(test, {:prompted, said})
      {:ok, Agent.get_and_update(steps, &step(&1, said))}
    end)
  end

  defp step(script, said) do
    {key, response} = Enum.find(script, fn {key, _response} -> String.contains?(said, key) end)
    {response, List.keydelete(script, key, 0)}
  end

  defp text(%{content: content}) when is_list(content),
    do: Enum.map_join(content, &(&1 |> Map.get(:text, "") |> to_string()))

  defp text(_message), do: ""

  defp define(scope, id, definition),
    do: run!(scope, "agent.define", Map.put(definition, "agent", id))

  test "defines a worker, asks it, and hears its answer back", %{scope: scope} do
    model([
      {"Watch the feed",
       calling([
         call("c1", "agent_define", %{
           "agent" => "watcher",
           "definition" => %{"model" => @model, "instructions" => "Watch."}
         })
       ])},
      {"\"id\"",
       calling([call("c2", "agent_ask", %{"agent" => "watcher", "message" => "What's new?"})])},
      {"msg_", answer("I asked the watcher.")},
      {"What's new?", answer("Two posts.")},
      {"From agent acme/watcher", answer("The watcher found two posts.")}
    ])

    define(scope, "acme/front", %{
      "model" => @model,
      "tools" => ["agents/*"],
      "policy" => %{"allow" => ["agent_ask"], "budget" => %{"tokens" => 100_000, "per" => "day"}}
    })

    run!(scope, "agent.ask", %{"agent" => "acme/front", "content" => "Watch the feed"})
    until("wardrik.run.interrupted")

    assert %{"interrupts" => [%{"id" => "c1", "name" => "agent_define"}]} =
             run!(scope, "agent.read", %{"agent" => "acme/front"})

    run!(scope, "agent.approve", %{"agent" => "acme/front", "interrupt" => "c1"})

    assert_receive {:prompted,
                    "From agent acme/watcher:\nIn answer to your message msg_" <> rest},
                   5_000

    assert rest =~ "Two posts."

    assert %{"definition" => %{"instructions" => "Watch."}} =
             run!(scope, "agent.definition", %{"agent" => "acme/watcher"})

    assert %{"budget" => _budget} =
             Wardrik.Definitions.boundary(Wardrik.Instance.fetch!(scope.wardrik), "acme/watcher")
  end

  test "reads agents freely, and changes their triggers only once allowed", %{scope: scope} do
    model([
      {"Look around",
       calling([
         call("r1", "agents_list", %{}),
         call("r2", "agent_read", %{"agent" => "worker"}),
         call("r3", "agent_definition_read", %{"agent" => "@jon/notes"}),
         call("r4", "self_definition_read", %{})
       ])},
      {"\"missing\"", answer("Seen.")},
      {"Schedule",
       calling([
         call("t1", "agent_trigger_set", %{
           "agent" => "worker",
           "trigger" => "daily",
           "fields" => %{"every" => "1d", "prompt" => "Go."}
         }),
         call("t2", "self_trigger_set", %{
           "trigger" => "mine",
           "fields" => %{"every" => "1h", "prompt" => "Me."}
         })
       ])},
      {"\"mine\"",
       calling([
         call("t3", "agent_trigger_remove", %{"agent" => "worker", "trigger" => "daily"}),
         call("t4", "self_trigger_remove", %{"trigger" => "mine"}),
         call("t5", "self_read", %{})
       ])},
      {"\"status\"", answer("Done.")}
    ])

    define(scope, "acme/worker", %{"model" => @model})
    define(scope, "acme/@jon/notes", %{"model" => @model})

    define(scope, "acme/front", %{
      "model" => @model,
      "tools" => ["agents/*", "self/*"],
      "policy" => %{
        "allow" => [
          "agent_trigger_set",
          "self_trigger_set",
          "agent_trigger_remove",
          "self_trigger_remove"
        ]
      }
    })

    run!(scope, "agent.ask", %{"agent" => "acme/front", "content" => "Look around"})
    until("wardrik.run.completed")

    run!(scope, "agent.ask", %{"agent" => "acme/front", "content" => "Schedule it"})
    until("wardrik.run.completed")

    assert %{"definition" => %{"triggers" => []}} =
             run!(scope, "agent.definition", %{"agent" => "acme/worker"})
  end

  test "brings back an answer that came while it wasn't running", %{scope: scope} do
    model([
      {"Ask the worker",
       calling([call("a1", "agent_ask", %{"agent" => "worker", "message" => "Sum 2 and 2"})])},
      {"msg_", answer("Asked.")},
      {"Sum 2 and 2", answer("4")},
      {"From agent acme/worker", answer("It's 4.")}
    ])

    define(scope, "acme/worker", %{"model" => @model})

    define(scope, "acme/front", %{
      "model" => @model,
      "tools" => ["agents/*"],
      "policy" => %{"allow" => ["agent_ask"]}
    })

    :ok = Supervisor.terminate_child(scope.wardrik, Wardrik.Delegation)
    run!(scope, "agent.ask", %{"agent" => "acme/front", "content" => "Ask the worker"})
    assert_receive {WardrikEvents, "acme/worker", %{"type" => "wardrik.run.completed"}}, 5_000
    refute_received {:prompted, "From agent" <> _rest}

    {:ok, _pid} = Supervisor.restart_child(scope.wardrik, Wardrik.Delegation)

    assert_receive {:prompted, "From agent acme/worker:\nIn answer to your message msg_" <> rest},
                   5_000

    assert rest =~ "4"
  end

  test "a message an agent sends carries what its run had read, and so does the answer", %{
    scope: scope
  } do
    model([
      {"Ask the worker",
       calling([call("a1", "agent_ask", %{"agent" => "worker", "message" => "Sum 2 and 2"})])},
      {"msg_", answer("Asked.")},
      {"Sum 2 and 2", answer("4")},
      {"From agent acme/worker", answer("It's 4.")}
    ])

    define(scope, "acme/worker", %{"model" => @model})

    define(scope, "acme/front", %{"model" => @model, "tools" => ["agents/*"], "policy" => "relay"})

    run!(%{scope | labels: ["outside"]}, "agent.ask", %{
      "agent" => "acme/front",
      "content" => "Ask the worker"
    })

    assert_receive {:prompted, "From agent acme/worker" <> _rest}, 5_000

    for _turn <- 1..2,
        do: assert_receive({WardrikEvents, "acme/front", %{"type" => "wardrik.run.completed"}})

    assert [%{metadata: %{labels: ["outside"]}} | _rest] = history(scope, "acme/worker")

    answer =
      scope
      |> history("acme/front")
      |> Enum.find(&(&1.metadata[:id] |> to_string() |> String.starts_with?("answer_")))

    assert %{metadata: %{labels: ["outside"]}} = answer
  end

  defp history(scope, id) do
    wardrik = Wardrik.Instance.fetch!(scope.wardrik)
    wardrik |> Wardrik.Operations.Running.whereis(id) |> WardrikCore.history()
  end

  test "names agents within the org, and lists them without their conversations", %{scope: scope} do
    define(scope, "acme/worker", %{"model" => @model})
    define(scope, "acme/@jon/notes", %{"model" => @model})
    define(scope, "globex/other", %{"model" => @model})

    tools =
      Wardrik.AgentTools.tools(WardrikCore.Context.new(agent_id: "acme/front/C1"),
        wardrik: scope.wardrik,
        reach: :agents
      )

    tool = fn name -> Enum.find(tools, &(&1.name == name)) end

    assert {:ok, %{"agents" => listed}} = tool.("agents_list").run.(%{}, nil)
    assert Enum.map(listed, & &1["id"]) |> Enum.sort() == ["acme/@jon/notes", "acme/worker"]

    assert {:ok, %{"definition" => _definition}} =
             tool.("agent_definition_read").run.(%{agent: "@jon/notes"}, nil)

    assert {:ok, %{"status" => _status}} = tool.("agent_read").run.(%{agent: "acme/worker"}, nil)
    assert {:error, message} = tool.("agent_read").run.(%{agent: "nobody"}, nil)
    assert message =~ "acme/nobody"
    assert {:error, _not_reached} = tool.("agent_read").run.(%{agent: "globex/other"}, nil)

    assert WardrikCore.Tool.annotation(tool.("agent_define"), :gated)
    assert WardrikCore.Tool.annotation(tool.("agents_list"), :read_only)
  end
end
