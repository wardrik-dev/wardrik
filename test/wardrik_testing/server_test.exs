defmodule WardrikTesting.ServerTest do
  use ExUnit.Case, async: true

  alias Wardrik.Scope
  alias WardrikTesting.Server

  setup context do
    name = :"server #{context.test}"
    store = WardrikStore.ETS.new(name: :"store #{context.test}")
    start_supervised!({WardrikStore, store})

    start_supervised!(
      {WardrikEvents,
       name: Server.events(name), store: store, deployment: "test", retention: :infinity}
    )

    :ok = Server.start(name, secrets: ["wrk_good"], offered: [{"acme/triage", ["chat"]}])
    :ok = WardrikEvents.subscribe(Server.events(name), ["*"])

    %{
      name: name,
      scope:
        Scope.new(Server,
          wardrik: name,
          principal: "acme/@ana",
          grants: [roles: [:messenger, :reader], resources: ["*"]]
        )
    }
  end

  test "knows the secrets it's given, until one is revoked", %{name: name} do
    assert {:ok, %Scope{server: Server, principal: %{id: "acme/@maria"}}} =
             Server.authenticate(name, "wrk_good")

    assert {:error, %Wardrik.Error{type: :unauthorized}} = Server.authenticate(name, "wrk_nope")
    :ok = Server.revoke(name, "wrk_good")
    assert {:error, _refused} = Server.authenticate(name, "wrk_good")
  end

  test "answers an operation with the protocol's example, tells the test, and finds no missing agent",
       %{scope: scope} do
    assert {:ok, %Wardrik.Agent{}} = Wardrik.Agent.define(scope, "acme/notes", model: "m")
    assert_received {:ran, "agent.define", %{"agent" => "acme/notes"}}

    assert :ok = Wardrik.Agent.forget(scope, "acme/notes")

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Agent.forget(scope, "acme/missing")

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Agent.ask(scope, "acme/missing/t1", "Hi")
  end

  test "lists and defines the agents it offers", %{name: name, scope: scope} do
    assert {:ok, [%Wardrik.Agent{id: "acme/triage"}]} = Wardrik.Agents.list(scope)

    assert {:ok, %Wardrik.Definition{channels: ["chat"]}, []} =
             Wardrik.Agent.definition(scope, "acme/triage")

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Agent.definition(scope, "acme/other")

    :ok =
      Server.add_agent(name,
        id: "acme/books",
        channels: ["chat"],
        description: "Keeps the books."
      )

    assert {:ok, [_triage, %Wardrik.Agent{id: "acme/books"}]} = Wardrik.Agents.list(scope)

    assert {:ok, %Wardrik.Definition{description: "Keeps the books."}, []} =
             Wardrik.Agent.definition(scope, "acme/books")

    :ok = Server.offer_agents(name, [])
    assert {:ok, []} = Wardrik.Agents.list(scope)
  end

  test "answers a message as a run does, in the conversation's log", %{scope: scope} do
    assert {:ok, %Wardrik.Message{}} = Wardrik.Agent.ask(scope, "acme/triage/t1", "Hi")
    assert_received {:asked, "acme/triage/t1", "Hi", "acme/@ana"}

    assert_receive {WardrikEvents, "acme/triage/t1", %{"type" => "wardrik.message.created"}}
    assert_receive {WardrikEvents, _log, %{"type" => "wardrik.run.started"}}
    assert_receive {WardrikEvents, _log, %{"type" => "wardrik.run.completed", "data" => data}}
    assert [%{"parts" => [%{"content" => "Answered: Hi"}]}] = data["messages"]

    Wardrik.Agent.ask(scope, "acme/triage/t2", "fail")
    assert_receive {WardrikEvents, "acme/triage/t2", %{"type" => "wardrik.run.failed"}}
  end

  test "waits on a call for a message saying echo, until it's decided or cancelled", %{
    scope: scope
  } do
    Wardrik.Agent.ask(scope, "acme/triage/t1", "echo hi")
    assert_receive {WardrikEvents, _log, %{"type" => "wardrik.run.interrupted"}}

    assert {:ok, %Wardrik.Agent{status: :parked, interrupts: [%Wardrik.Interrupt{id: "call_1"}]}} =
             Wardrik.Agent.read(scope, "acme/triage/t1")

    assert {:error, %Wardrik.Error{type: :forbidden}} =
             Wardrik.Agent.approve(scope, agent: "acme/triage/t1", interrupt: "call_1")

    decider = Wardrik.Scope.grant(scope, roles: [:approver], resources: ["acme/agent/*"])

    assert {:ok, [%Wardrik.Decision{decision: :rejected}]} =
             Wardrik.Agent.deny(decider,
               agent: "acme/triage/t1",
               interrupt: "call_1",
               reason: "No."
             )

    assert_receive {WardrikEvents, _log,
                    %{"type" => "wardrik.interrupt.resolved", "data" => %{"reason" => "No."}}}

    assert {:ok, %Wardrik.Agent{status: :idle}} = Wardrik.Agent.read(scope, "acme/triage/t1")

    Wardrik.Agent.ask(scope, "acme/triage/t3", "echo")
    Wardrik.Agent.deny(decider, agent: "acme/triage/t3", interrupt: "call_1")

    assert_receive {WardrikEvents, "acme/triage/t3",
                    %{
                      "type" => "wardrik.interrupt.resolved",
                      "data" => %{"reason" => "Rejected."}
                    }}

    Wardrik.Agent.ask(scope, "acme/triage/t2", "echo")
    assert :ok = Wardrik.Agent.cancel(scope, "acme/triage/t2")
    assert_receive {WardrikEvents, "acme/triage/t2", %{"type" => "wardrik.run.cancelled"}}
  end

  test "streams an event and then follows quietly, or says why it can't", %{scope: scope} do
    assert {:ok, stream} = Wardrik.Agent.stream_events(scope, "acme/triage")
    assert [{%Wardrik.Event{type: "wardrik.run.completed"}, "cursor-1"}] = Enum.take(stream, 1)
    assert_received {:streamed, "agent.events", %{"agent" => "acme/triage"}}

    assert {:error, %Wardrik.Error{type: :invalid_request}} =
             Wardrik.Agent.stream_events(scope, "acme/triage", after: "nope")
  end

  test "replies as the agent named says: answered, waiting or failed", %{scope: scope} do
    assert {:ok, %Wardrik.Reply{text: "Re: hi"}} = Wardrik.Agent.reply(scope, "acme/triage", "hi")

    assert {:waiting, [%Wardrik.Interrupt{id: "call_1"}]} =
             Wardrik.Agent.reply(scope, "acme/waiting", "hi")

    assert {:error, %Wardrik.Error{}} = Wardrik.Agent.reply(scope, "acme/broken", "hi")
  end

  test "tells the test what a worker offers, and answers a call to its caller", %{
    name: name,
    scope: scope
  } do
    assert :ok = Server.offer(scope, [%{"name" => "lookup"}])
    assert_received {:offered, pid, [%{"name" => "lookup"}]}
    assert pid == self()

    ref = make_ref()
    assert :ok = Server.answer({self(), ref}, %{"result" => %{}})
    assert_received {^ref, %{"result" => %{}}}

    Process.unregister(name)
    assert Server.tell(name, :nobody) == :ok
  end

  test "writes no log where the test started no events", context do
    name = :"quiet #{context.test}"
    Process.unregister(context.name)
    :ok = Server.start(name)

    scope =
      Scope.new(Server,
        wardrik: name,
        principal: "acme/@ana",
        grants: [roles: [:messenger], resources: ["*"]]
      )

    assert {:ok, %Wardrik.Message{}} = Wardrik.Agent.ask(scope, "acme/triage/t1", "Hi")
  end
end
