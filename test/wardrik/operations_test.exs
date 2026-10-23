defmodule Wardrik.OperationsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Operations.Visible
  alias Wardrik.Statement
  alias WardrikEvents.Cursor

  setup :set_mimic_global
  setup :start_wardrik

  setup %{wardrik: wardrik} do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
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
               run!(scope, "agents.list", %{"resources" => ["acme/agent/*"]})

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

      reader = Statement.new(roles: [:reader], resources: ["acme/agent/*"])
      %{reader: Wardrik.as(wardrik, maria(), [reader])}
    end

    test "lists only those", %{scope: scope, reader: reader} do
      assert %{"agents" => [%{"id" => "acme/triage", "status" => "idle", "name" => "triage"}]} =
               run!(reader, "agents.list", %{})

      ids = for %{"id" => id} <- run!(scope, "agents.list", %{})["agents"], do: id
      assert ids == ["acme/@jon/books", "acme/triage", "globex/triage"]

      ids =
        for %{"id" => id} <- run!(scope, "agents.list", %{"resources" => ["acme/*"]})["agents"],
            do: id

      assert ids == ["acme/@jon/books", "acme/triage"]
    end

    test "reads only their events, and only their place in the cursor", %{
      scope: scope,
      reader: reader
    } do
      %{"events" => events, "next" => next} = run!(reader, "events.list", %{})

      assert events |> Enum.map(&Visible.agent_id/1) |> Enum.uniq() == [
               "acme/triage"
             ]

      assert {:ok, %{"acme/triage" => _sequence} = cursor} = Cursor.decode(next)
      assert map_size(cursor) == 1

      %{"cursor" => head} = run!(reader, "events.head", %{})
      assert {:ok, ^cursor} = Cursor.decode(head)

      %{"events" => completed} =
        run!(scope, "events.list", %{
          "resources" => ["acme/*"],
          "types" => ["wardrik.run.completed"]
        })

      assert completed |> Enum.map(&Visible.agent_id/1) |> Enum.sort() ==
               ["acme/@jon/books", "acme/triage"]
    end

    test "follows only their events", %{scope: scope, reader: reader} do
      %{"cursor" => head} = run!(scope, "events.head", %{})

      {:ok, stream} =
        Wardrik.stream(reader, "events.list", %{
          "after" => head,
          "types" => ["wardrik.message.created"]
        })

      answers([answer("Four."), answer("Five.")])
      run!(scope, "agent.ask", %{"agent" => "globex/triage", "content" => "Hi"})
      run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Hi"})

      assert [{event, cursor}] = Enum.take(stream, 1)
      assert Visible.agent_id(event) == "acme/triage"
      assert {:ok, cursor} = Cursor.decode(cursor)
      assert Map.keys(cursor) == ["acme/triage"]
    end

    test "hides the others, and refuses what it may not do", %{reader: reader} do
      assert refused(reader, "agent.read", %{"agent" => "globex/triage"}) == :not_found
      assert refused(reader, "agent.read", %{"agent" => "acme/@jon/books"}) == :not_found

      assert refused(reader, "agent.ask", %{"agent" => "acme/triage", "content" => "Hi"}) ==
               :forbidden

      assert refused(reader, "audit.list", %{}) == :not_found
    end
  end

  describe "what the runner refuses" do
    test "input its schema doesn't take", %{scope: scope} do
      assert refused(scope, "agent.ask", %{"agent" => "acme/triage"}) == :invalid_request
      assert refused(scope, "agent.read", %{"agent" => "acme"}) == :invalid_request
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
    change = {"agent.forgotten", "agents/acme/triage", %{"agent" => %{"id" => "acme/triage"}}}
    :ok = WardrikEvents.record(Wardrik.events(wardrik), change, actor: maria())

    assert %{"events" => [%{"type" => "wardrik.agent.forgotten"}], "next" => next} =
             run!(scope, "audit.list", %{"limit" => 10})

    assert %{"events" => []} = run!(scope, "audit.list", %{"starting_after" => next})
  end
end
