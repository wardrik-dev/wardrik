defmodule Wardrik.OperationsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Operations.Visible
  alias WardrikEvents.Cursor

  setup :set_mimic_global
  setup :start_wardrik

  setup %{wardrik: wardrik} do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), :all)
    %{scope: owner(wardrik)}
  end

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  describe "talking to an agent" do
    test "asks, and reads back what it did", %{wardrik: wardrik, scope: scope} do
      answers([answer("Nothing's on fire.")])
      start_agent(wardrik, "acme/triage")

      %{"message" => %{"id" => "msg_1", "cursor" => cursor}} =
        run!(scope, "agent.ask", %{"agent" => "acme/triage", "id" => "msg_1", "content" => "Hi"})

      until("wardrik.run.completed")

      assert %{"status" => "idle", "pending" => 0, "interrupts" => []} =
               run!(scope, "agent.read", %{"agent" => "acme/triage"})

      %{"events" => events} =
        run!(scope, "agent.events", %{
          "agent" => "acme/triage",
          "after" => cursor,
          "types" => ["wardrik.run.completed"]
        })

      assert [%{"type" => "wardrik.run.completed"}] = events

      assert %{"items" => [%{"kind" => "user", "text" => "Hi"}, %{"kind" => "run"} = run]} =
               run!(scope, "agent.timeline", %{"agent" => "acme/triage"})

      assert %{"status" => "completed", "steps" => [%{"text" => "Nothing's on fire."}]} = run

      assert %{"runs" => [%{"status" => "completed"}], "totals" => %{"runs" => 1}} =
               run!(scope, "agent.runs", %{"agent" => "acme/triage"})
    end

    test "takes a message as parts", %{wardrik: wardrik, scope: scope} do
      answers([answer("Hello.")])
      start_agent(wardrik, "acme/triage")

      parts = [%{"type" => "text", "content" => "Hi"}, %{"type" => "text", "content" => "there"}]

      %{"message" => %{"id" => "msg_" <> _}} =
        run!(scope, "agent.ask", %{"agent" => "acme/triage", "parts" => parts})

      %{"data" => %{"message" => message}} = until("wardrik.message.created")
      assert [%{"content" => "Hi\n\nthere"}] = message["parts"]
    end

    test "follows an agent's log from a cursor", %{wardrik: wardrik, scope: scope} do
      answers([answer("Hello.")])
      start_agent(wardrik, "acme/triage")

      %{"message" => %{"cursor" => cursor}} =
        run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Hi"})

      {:ok, stream} =
        Wardrik.stream(scope, "agent.events", %{
          "agent" => "acme/triage",
          "after" => cursor,
          "types" => ["wardrik.run.completed"]
        })

      assert [{%{"type" => "wardrik.run.completed"}, next}] = Enum.take(stream, 1)

      assert %{"events" => []} =
               run!(scope, "agent.events", %{"agent" => "acme/triage", "after" => next})
    end

    test "stops what it's doing", %{wardrik: wardrik, scope: scope} do
      answers([calling([call("call_1", "echo", %{"text" => "hi"})])])
      start_agent(wardrik, "acme/triage")
      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Echo hi"})
      until("wardrik.run.interrupted")

      assert run!(scope, "agent.cancel", %{"agent" => "acme/triage"}) == nil
      until("wardrik.run.cancelled")
      assert run!(scope, "agent.cancel", %{"agent" => "acme/triage"}) == nil
    end
  end

  test "waits on each call until it's decided, in any order", %{wardrik: wardrik, scope: scope} do
    calls = [
      call("call_1", "echo", %{"text" => "one"}),
      call("call_2", "echo", %{"text" => "two"})
    ]

    answers([calling(calls), answer("Done.")])
    start_agent(wardrik, "acme/triage")
    run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Echo twice"})
    until("wardrik.run.interrupted")

    run!(scope, "agent.approve", %{"agent" => "acme/triage", "interrupt" => "call_2"})
    until("wardrik.run.interrupted")

    assert %{"status" => "parked", "interrupts" => [%{"id" => "call_1"}]} =
             run!(scope, "agent.read", %{"agent" => "acme/triage"})

    assert refused(scope, "agent.deny", %{"agent" => "acme/triage", "interrupt" => "call_2"}) ==
             :conflict

    run!(scope, "agent.approve", %{"agent" => "acme/triage", "interrupt" => "call_1"})
    until("wardrik.run.completed")

    assert %{"status" => "idle", "interrupts" => []} =
             run!(scope, "agent.read", %{"agent" => "acme/triage"})
  end

  describe "answering a call an agent waits on" do
    setup %{wardrik: wardrik, scope: scope} do
      answers([calling([call("call_1", "echo", %{"text" => "hi"})]), answer("Done.")])
      start_agent(wardrik, "acme/triage")
      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Echo hi"})
      until("wardrik.run.interrupted")
      :ok
    end

    test "lists it, and approves it", %{scope: scope} do
      assert %{"status" => "parked", "interrupts" => [%{"id" => "call_1"}]} =
               run!(scope, "agent.read", %{"agent" => "acme/triage"})

      assert %{
               "interrupts" => [
                 %{"agent" => %{"id" => "acme/triage"}, "interrupt" => %{"id" => "call_1"}}
               ]
             } =
               run!(scope, "interrupts.list", %{})

      assert %{"agents" => [%{"id" => "acme/triage", "status" => "parked"}]} =
               run!(scope, "agents.list", %{"agents" => ["acme/triage"]})

      assert %{"parked" => 1, "running" => 0} = run!(scope, "deployment.nodes", %{})

      assert %{"decisions" => [%{"id" => "call_1", "decision" => "approved"}]} =
               run!(scope, "agent.approve", %{
                 "agent" => "acme/triage",
                 "interrupt" => "call_1",
                 "note" => "Once."
               })

      assert %{"data" => %{"status" => "ok"}} = until("wardrik.tool_call.completed")
      until("wardrik.run.completed")
    end

    test "denies it, and tells the model why", %{scope: scope} do
      assert %{"decisions" => [%{"decision" => "rejected"}]} =
               run!(scope, "agent.deny", %{"agent" => "acme/triage", "interrupt" => "call_1"})

      assert %{"data" => %{"status" => "error"}} = until("wardrik.tool_call.completed")
    end

    test "refuses a call it doesn't wait on", %{scope: scope} do
      decisions = [%{"id" => "call_9", "decision" => "approve"}]

      assert refused(scope, "agent.decide", %{"agent" => "acme/triage", "decisions" => decisions}) ==
               :conflict

      decisions = [%{"id" => "call_1", "decision" => "reject", "reason" => "No."}]
      run!(scope, "agent.decide", %{"agent" => "acme/triage", "decisions" => decisions})
      until("wardrik.run.completed")

      assert refused(scope, "agent.decide", %{"agent" => "acme/triage", "decisions" => decisions}) ==
               :conflict
    end
  end

  test "says where a person signs in for a call", %{wardrik: wardrik, scope: scope} do
    answers([calling([call("call_1", "inbox", %{})])])
    agent = start_agent(wardrik, "acme/triage")
    run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Read my mail"})
    until("wardrik.run.interrupted")

    assert %{"url" => "https://example.com/sign-in"} =
             run!(scope, "agent.authorization", %{
               "agent" => "acme/triage",
               "interrupt" => "call_1"
             })

    assert refused(scope, "agent.authorization", %{
             "agent" => "acme/triage",
             "interrupt" => "call_2"
           }) ==
             :not_found

    :ok = WardrikCore.interrupt(agent)
    until("wardrik.run.cancelled")

    assert refused(scope, "agent.authorization", %{
             "agent" => "acme/triage",
             "interrupt" => "call_1"
           }) ==
             :not_found
  end

  describe "the agents a scope reaches" do
    setup %{wardrik: wardrik, scope: scope} do
      answers([answer("One."), answer("Two."), answer("Three.")])

      for id <- ["acme/triage", "acme/@jon/books", "globex/triage"] do
        start_agent(wardrik, id)
        run!(scope, "agent.ask", %{"agent" => id, "content" => "Hi"})
        until("wardrik.run.completed")
      end

      %{reader: limited(wardrik, maria(), roles: [:reader], agents_of: ["acme"])}
    end

    test "lists only those", %{scope: scope, reader: reader} do
      assert %{"agents" => [%{"id" => "acme/triage", "status" => "idle"} = triage]} =
               run!(reader, "agents.list", %{})

      refute Map.has_key?(triage, "name")
      refute Map.has_key?(triage, "conversation")

      ids = for %{"id" => id} <- run!(scope, "agents.list", %{})["agents"], do: id
      assert ids == ["acme/@jon/books", "acme/triage", "globex/triage"]

      named = %{"agents" => ["acme/@jon/books", "acme/triage", "acme/nobody"]}
      ids = for %{"id" => id} <- run!(scope, "agents.list", named)["agents"], do: id
      assert ids == ["acme/@jon/books", "acme/triage"]

      named = %{"agents" => ["acme/@jon/books", "acme/triage"]}
      ids = for %{"id" => id} <- run!(reader, "agents.list", named)["agents"], do: id
      assert ids == ["acme/triage"]

      assert refused(scope, "agents.list", %{"resources" => ["acme/*"]}) == :invalid_request

      assert run!(scope, "agents.list", %{"agents" => ["acme/*"]}) == %{
               "agents" => [],
               "next" => nil
             }
    end

    test "reads only their events, and only their place in the cursor", %{
      scope: scope,
      reader: reader
    } do
      both = %{"agents" => ["acme/triage", "globex/triage"]}
      %{"events" => events, "next" => next} = run!(reader, "events.list", both)

      assert events |> Enum.map(&Visible.agent_id/1) |> Enum.uniq() == [
               "acme/triage"
             ]

      assert {:ok, %{{"acme/triage", nil} => _sequence} = cursor} = Cursor.decode(next)
      assert map_size(cursor) == 1

      %{"cursor" => head} = run!(reader, "events.head", both)
      assert {:ok, ^cursor} = Cursor.decode(head)

      %{"events" => completed} =
        run!(scope, "events.list", %{
          "agents" => ["acme/@jon/books", "acme/triage"],
          "types" => ["wardrik.run.completed"]
        })

      assert completed |> Enum.map(&Visible.agent_id/1) |> Enum.sort() ==
               ["acme/@jon/books", "acme/triage"]
    end

    test "follows only their events", %{scope: scope, reader: reader} do
      both = ["acme/triage", "globex/triage"]
      %{"cursor" => head} = run!(scope, "events.head", %{"agents" => both})

      {:ok, stream} =
        Wardrik.stream(reader, "events.list", %{
          "agents" => both,
          "after" => head,
          "types" => ["wardrik.message.created"]
        })

      answers([answer("Four."), answer("Five.")])
      run!(scope, "agent.ask", %{"agent" => "globex/triage", "content" => "Hi"})
      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Hi"})

      assert [{event, cursor}] = Enum.take(stream, 1)
      assert Visible.agent_id(event) == "acme/triage"
      assert {:ok, cursor} = Cursor.decode(cursor)
      assert Map.keys(cursor) == [{"acme/triage", nil}]
    end

    test "hides the others, and refuses what it may not do", %{reader: reader} do
      assert refused(reader, "agent.read", %{"agent" => "globex/triage"}) == :not_found
      assert refused(reader, "agent.read", %{"agent" => "acme/@jon/books"}) == :not_found

      assert refused(reader, "agent.ask", %{"agent" => "acme/triage", "content" => "Hi"}) ==
               :forbidden

      assert refused(reader, "audit.list", %{}) == :not_found
    end
  end

  describe "a conversation" do
    setup %{wardrik: wardrik, scope: scope} do
      echo = calling([call("call_1", "echo", %{"text" => "hi"})])
      answers([echo, echo, answer("Done.")])

      for id <- ["acme/triage", "globex/triage"] do
        start_agent(wardrik, id, conversation: "C1")
        run!(scope, "agent.ask", %{"agent" => id, "conversation" => "C1", "content" => "Echo"})
        until("wardrik.run.interrupted")
      end

      roles = [:reader, :messenger, :approver]
      %{reader: limited(wardrik, maria(), roles: roles, agents_of: ["acme"])}
    end

    test "is reached only through its agent's authorization", %{reader: reader} do
      sample = %{
        "content" => "Hi",
        "interrupt" => "call_1",
        "decisions" => [%{"id" => "call_1", "decision" => "approve"}],
        "call" => "call_1",
        "node" => "nonode@nohost"
      }

      routed =
        for %{conversation: route} = operation <- WardrikProtocol.operations(),
            route,
            do: operation

      assert routed |> Enum.map(& &1.id) |> Enum.sort() ==
               ~w(agent.approve agent.ask agent.authorization agent.calls agent.cancel agent.clear
                  agent.decide agent.deny agent.events agent.kill agent.move agent.read agent.runs
                  agent.stop agent.timeline)

      for operation <- routed do
        input = Map.take(sample, Map.keys(operation.input["properties"]))
        hidden = Map.merge(input, %{"agent" => "globex/triage", "conversation" => "C1"})
        assert refused(reader, operation.id, hidden) == :not_found, operation.id
      end

      seen = %{"agent" => "acme/triage", "conversation" => "C1"}

      assert %{"conversation" => "C1", "interrupts" => [%{"id" => "call_1"}], "cursor" => cursor} =
               run!(reader, "agent.read", seen)

      assert {:ok, %{{"acme/triage", "C1"} => _sequence} = positions} = Cursor.decode(cursor)
      assert map_size(positions) == 1
      assert %{"events" => [_event | _events]} = run!(reader, "agent.events", seen)

      assert %{"decisions" => [%{"decision" => "approved"}]} =
               run!(reader, "agent.approve", Map.put(seen, "interrupt", "call_1"))
    end

    test "is listed, and its events and interrupts read, only through its agent's", %{
      scope: scope,
      reader: reader
    } do
      assert [%{"id" => "acme/triage", "conversation" => "C1"}] =
               run!(reader, "agents.list", %{})["agents"]

      assert run!(reader, "agents.list", %{"agents" => ["globex/triage"]})["agents"] == []

      assert [%{"agent" => %{"id" => "acme/triage"}, "conversation" => "C1"}] =
               run!(reader, "interrupts.list", %{})["interrupts"]

      both = %{"agents" => ["acme/triage", "globex/triage"]}
      %{"events" => events, "next" => next} = run!(reader, "events.list", both)
      assert events != []

      assert Enum.uniq(for event <- events, do: {event["agent"], event["conversation"]}) == [
               {"acme/triage", "C1"}
             ]

      assert run!(reader, "events.list", %{"agents" => ["globex/triage"]})["events"] == []

      %{"cursor" => everything} = run!(scope, "events.head", both)
      {:ok, all} = Cursor.decode(everything)
      assert Map.has_key?(all, {"globex/triage", "C1"})

      %{"cursor" => head} = run!(reader, "events.head", both)
      %{"next" => after_all} = run!(reader, "events.list", Map.put(both, "after", everything))

      for cursor <- [next, head, after_all] do
        assert {:ok, positions} = Cursor.decode(cursor)
        assert Map.keys(positions) == [{"acme/triage", "C1"}]
      end
    end

    test "asks the authorizer about its agent, and tells it the conversation", %{
      wardrik: wardrik
    } do
      test = self()

      decide = fn request ->
        send(test, {:authorize, request})
        :ok
      end

      scope = Wardrik.as(wardrik, maria(), context: %{decide: decide})
      seen = %{"agent" => "acme/triage", "conversation" => "C1"}

      for {operation, input} <- [
            {"agent.read", seen},
            {"agent.events", seen},
            {"agent.ask", Map.put(seen, "content", "Hi")},
            {"agent.approve", Map.put(seen, "interrupt", "call_1")}
          ] do
        run!(scope, operation, input)

        assert_received {:authorize,
                         %{resource: {:agent, "acme/triage"}, context: %{conversation: "C1"}}},
                        operation
      end
    end
  end

  describe "what the runner refuses" do
    test "input its schema doesn't take", %{scope: scope} do
      assert refused(scope, "agent.ask", %{"agent" => "acme/triage"}) == :invalid_request

      for id <- ["", "acme\ntriage", String.duplicate("a", 256)] do
        assert refused(scope, "agent.read", %{"agent" => id}) == :invalid_request

        assert refused(scope, "agent.read", %{"agent" => "acme/triage", "conversation" => id}) ==
                 :invalid_request
      end

      assert refused(scope, "events.list", %{"after" => "not a cursor"}) == :invalid_request

      assert refused(scope, "agent.events", %{"agent" => "acme/triage", "after" => "nope"}) ==
               :invalid_request
    end

    test "an agent that isn't running, an operation there isn't, and a stream there isn't", %{
      scope: scope
    } do
      for id <- ~w(agent.read agent.ask agent.cancel agent.authorization) do
        input = %{"agent" => "acme/nobody", "content" => "Hi", "interrupt" => "call_1"}
        input = Map.take(input, Map.keys(WardrikProtocol.operation(id).input["properties"]))
        assert refused(scope, id, input) == :not_found
      end

      assert refused(scope, "agent.unknown", %{}) == :not_found

      assert {:error, %Wardrik.Error{type: :not_supported}} =
               Wardrik.stream(scope, "agent.read", %{"agent" => "acme/triage"})

      assert {:error, %Wardrik.Error{type: :invalid_request}} =
               Wardrik.stream(scope, "events.list", %{"after" => "nope"})
    end
  end

  test "reads the audit", %{wardrik: wardrik, scope: scope} do
    change = {"agent.forgotten", "agents/acme%2Ftriage", %{"agent" => %{"id" => "acme/triage"}}}
    :ok = WardrikEvents.record(Wardrik.events(wardrik), change, actor: maria())

    assert %{"events" => [%{"type" => "wardrik.agent.forgotten"}], "next" => next} =
             run!(scope, "audit.list", %{"limit" => 10})

    assert %{"events" => []} = run!(scope, "audit.list", %{"starting_after" => next})
  end
end
