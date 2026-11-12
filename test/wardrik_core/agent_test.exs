defmodule WardrikCore.AgentTest do
  use ExUnit.Case, async: false
  use Mimic
  @moduletag :capture_log

  import WardrikCore.Test.LLM

  alias WardrikCore.Test.Echo

  defmodule Trace do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%WardrikCore.Context{step: :turn} = context, next, _opts) do
      trace = Map.get_lazy(context.metadata, :trace, fn -> System.unique_integer() end)
      send(WardrikCore.AgentTest, {:trace, trace})
      next.(put_in(context.metadata[:trace], trace))
    end

    def call(context, next, _opts), do: next.(context)
  end

  defmodule Counter do
    @behaviour WardrikCore.Middleware

    alias WardrikCore.Context

    @impl true
    def call(%Context{step: :turn} = context, next, _opts) do
      context = Context.update_private(context, __MODULE__, 1, &(&1 + 1))
      send(WardrikCore.AgentTest, {:turns, Context.get_private(context, __MODULE__)})
      next.(context)
    end

    def call(context, next, _opts), do: next.(context)
  end

  defmodule Blocking do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context, _opts) do
      [
        WardrikCore.Tool.new!(
          name: "block",
          description: "Blocks until released",
          run: fn _args, %{step: {:tool_call, call}} ->
            send(WardrikCore.AgentTest, {:tool_running, call.id, self()})
            receive do: (:release -> {:ok, "released"})
          end,
          annotations: [idempotent: true]
        )
      ]
    end
  end

  alias WardrikCore.Principal
  alias WardrikCore.Test.ParkTools

  setup :set_mimic_global

  setup do
    handler = "agent-test-#{System.unique_integer([:positive])}"

    events = [
      [:wardrik_core, :agent, :start],
      [:wardrik_core, :agent, :stop],
      [:wardrik_core, :message, :queued],
      [:wardrik_core, :turn, :start],
      [:wardrik_core, :turn, :stop],
      [:wardrik_core, :turn, :checkpoint],
      [:wardrik_core, :step, :stop]
    ]

    :telemetry.attach_many(handler, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok
  end

  def handle_event([:wardrik_core | event], _measurements, metadata, test),
    do: send(test, {event, metadata})

  test "a turn that crashes leaves the agent running and its message in history" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> raise "boom" end)
    {id, agent} = start_agent()

    WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :crash}}

    assert %{state: :idle, in_flight: [], messages: [%{role: :user}]} = agent_state(agent)
  end

  test "a turn that fails leaves its message in history" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:error, :rate_limited} end)
    {id, agent} = start_agent()

    WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :error, reason: _reason}}

    assert %{state: :idle, in_flight: [], messages: [%{role: :user}]} = agent_state(agent)
  end

  test "a message survives the agent dying mid-turn, and runs when it comes back" do
    test = self()

    ReqLLM
    |> expect(:stream_text, fn _, _, _ ->
      send(test, :generating)
      receive do: (:never -> :ok)
    end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent()
    WardrikCore.ask(agent, "hi")
    assert_receive :generating

    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    {^id, agent} = start_agent(agent_id: id)

    assert_receive {[:turn, :stop],
                    %{agent_id: ^id, outcome: :ok, messages: [%{role: :assistant}]}}

    assert %{messages: messages} = agent_state(agent)
    assert [:user, :assistant] = Enum.map(messages, & &1.role)
  end

  test "an agent killed while its tools run comes back by itself and finishes its turn" do
    Process.register(self(), WardrikCore.AgentTest)
    backend = {WardrikCore.Backends.MemoryStore, name: :crash_test}
    start_supervised!({WardrikCore.Backends.MemoryStore, name: :crash_test})

    start_supervised!(
      {WardrikCore,
       name: CrashTest,
       prefix: "crash/",
       backend: backend,
       discovery_interval_ms: 50,
       initial_discovery_delay_ms: 0}
    )

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("call-a", "block")])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    id = "agent-#{System.unique_integer([:positive])}"

    {:ok, agent} =
      WardrikCore.start_agent(CrashTest,
        agent_id: id,
        model: "anthropic:claude-haiku-4-5",
        capabilities: [Blocking]
      )

    WardrikCore.ask(agent, "hi")
    assert_receive {:tool_running, "call-a", _tool}
    assert_receive {[:turn, :checkpoint], %{agent_id: ^id}}
    Process.exit(agent, :kill)

    assert_receive {[:turn, :start], %{agent_id: ^id, kind: :recover}}, 5_000
    assert_receive {:tool_running, "call-a", tool}
    send(tool, :release)
    assert_receive {[:turn, :stop], %{agent_id: ^id, kind: :recover, outcome: :ok}}
  end

  test "an agent lost while its tools run recovers the batch without asking the model again" do
    Process.register(self(), WardrikCore.AgentTest)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("call-a", "block")])} end)
    |> expect(:stream_text, fn _, messages, _ ->
      assert %{role: :tool, tool_call_id: "call-a"} = List.last(messages)
      {:ok, answer("done")}
    end)

    {id, agent} = start_agent(capabilities: [Blocking])
    WardrikCore.ask(agent, "hi")
    assert_receive {:tool_running, "call-a", _tool}
    assert_receive {[:turn, :checkpoint], %{agent_id: ^id}}

    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    {^id, agent} = start_agent(agent_id: id, capabilities: [Blocking])
    assert_receive {[:agent, :start], %{agent_id: ^id, state: :due}}
    assert_receive {[:turn, :start], %{agent_id: ^id, kind: :recover}}
    assert_receive {:tool_running, "call-a", tool}
    send(tool, :release)
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

    assert %{state: :idle, checkpoint: nil, in_flight: [], messages: messages} =
             agent_state(agent)

    assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
  end

  test "gives each message an id, keeping one it was given" do
    ReqLLM
    |> stub(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent()
    WardrikCore.ask(agent, "hi")

    assert_receive {[:message, :queued],
                    %{agent_id: ^id, message: %{metadata: %{id: "msg_" <> _random}}}}

    WardrikCore.ask(agent, "again", %{id: "mine"})
    assert_receive {[:message, :queued], %{agent_id: ^id, message: %{metadata: %{id: "mine"}}}}
  end

  describe "instructions" do
    test "are the system prompt of every model call, and never part of the conversation" do
      ReqLLM
      |> expect(:stream_text, fn _, [system, %{role: :user}], _ ->
        assert %{role: :system, content: [%{text: "Be brief."}]} = system
        {:ok, answer("Hi.")}
      end)
      |> expect(:stream_text, fn _, [system | _messages], _ ->
        assert %{role: :system, content: [%{text: "Be kind."}]} = system
        {:ok, answer("Hello.")}
      end)

      {id, agent} = start_agent(instructions: "Be brief.")
      WardrikCore.ask(agent, "hi")
      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

      assert [:user, :assistant] = agent |> WardrikCore.history() |> Enum.map(& &1.role)

      :ok = WardrikCore.configure(agent, instructions: "Be kind.")
      WardrikCore.ask(agent, "hello")
      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    end
  end

  describe "kill/2" do
    test "stops one running call, and the turn goes on without it" do
      Process.register(self(), WardrikCore.AgentTest)

      ReqLLM
      |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("call-a", "block")])} end)
      |> expect(:stream_text, fn _, messages, _ ->
        assert %{role: :tool} = tool_result = List.last(messages)
        assert [%{text: text}] = tool_result.content
        assert text =~ "The call was stopped before it finished."
        {:ok, answer("done")}
      end)

      {id, agent} = start_agent(capabilities: [Blocking])
      WardrikCore.ask(agent, "first")
      assert_receive {:tool_running, "call-a", tool}
      tool_ref = Process.monitor(tool)

      assert :ok = WardrikCore.kill(agent, "call-a")
      assert_receive {:DOWN, ^tool_ref, :process, _pid, :killed}
      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

      assert {:error, :not_running} = WardrikCore.kill(agent, "call-a")
    end

    test "has nothing to stop on a call it isn't running" do
      {_id, agent} = start_agent()

      assert {:error, :not_running} = WardrikCore.kill(agent, "call-9")
    end
  end

  describe "nodes/1, placements/1, running/1 and move/3" do
    test "say where each agent runs, and start one again where it's told" do
      here = to_string(node())
      {id, agent} = start_agent()

      assert here in WardrikCore.nodes()
      assert %{{^id, nil} => ^here} = WardrikCore.placements()
      assert %{{^id, nil} => ^agent} = WardrikCore.running()

      assert {:ok, moved} = WardrikCore.move(id, to: here)
      refute moved == agent
      assert %{agent_id: ^id, state: :idle} = agent_state(moved)

      assert {:error, :no_such_node} = WardrikCore.move(id, to: "nowhere@nohost")
      assert {:error, :not_found} = WardrikCore.move("agent-never", to: here)

      :ok = WardrikCore.stop(moved)
      assert %{{^id, nil} => nil} = WardrikCore.placements()
      refute Map.has_key?(WardrikCore.running(), {id, nil})
    end
  end

  describe "delete/2" do
    test "stops an agent and forgets it" do
      {id, agent} = start_agent()
      ref = Process.monitor(agent)

      assert :ok = WardrikCore.delete(id)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      refute {id, nil} in WardrikCore.list()
      assert :ok = WardrikCore.delete(id)
    end
  end

  describe "interrupt/1" do
    test "stops a running turn and its tools, then runs what was queued behind it" do
      Process.register(self(), WardrikCore.AgentTest)

      ReqLLM
      |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("call-a", "block")])} end)
      |> expect(:stream_text, fn _, messages, _ ->
        assert [:user, :user] = Enum.map(messages, & &1.role)
        {:ok, answer("done")}
      end)

      {id, agent} = start_agent(capabilities: [Blocking])
      WardrikCore.ask(agent, "first")
      assert_receive {:tool_running, "call-a", tool}
      WardrikCore.ask(agent, "second")
      tool_ref = Process.monitor(tool)

      assert :ok = WardrikCore.interrupt(agent)
      assert_receive {:DOWN, ^tool_ref, :process, _pid, _reason}

      assert_receive {[:turn, :stop],
                      %{agent_id: ^id, outcome: :interrupted, kept: 1, dropped: 0}}

      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

      assert %{state: :idle, checkpoint: nil, messages: messages} = agent_state(agent)
      assert [:user, :user, :assistant] = Enum.map(messages, & &1.role)
    end

    test "drops a parked turn without its unanswered tool request" do
      expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)

      {id, agent} = start_agent(middleware: [ParkTools])
      WardrikCore.ask(agent, "hi")
      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :park}}

      assert :ok = WardrikCore.interrupt(agent)

      assert_receive {[:turn, :stop],
                      %{agent_id: ^id, outcome: :interrupted, kept: 1, dropped: 0}}

      assert %{state: :idle, parked: nil, messages: [%{role: :user}]} = agent_state(agent)
      assert {:error, :not_parked} = WardrikCore.resume(agent, %{"1" => :approve})
    end

    test "has nothing to stop on an idle agent" do
      {_id, agent} = start_agent()

      assert {:error, :idle} = WardrikCore.interrupt(agent)
    end
  end

  test "a turn past its timeout is stopped" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> receive do: (:never -> :ok) end)

    {id, agent} = start_agent(timeout: 50)
    WardrikCore.ask(agent, "hi")

    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :timeout}}
    assert %{state: :idle, messages: [%{role: :user}]} = agent_state(agent)
  end

  test "a message sent during a turn steers it: the turn yields, and the next one answers it" do
    Process.register(self(), WardrikCore.AgentTest)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("call-a", "block")])} end)
    |> expect(:stream_text, fn _, messages, _ ->
      assert [:user, :assistant, :tool, :user] = Enum.map(messages, & &1.role)
      {:ok, answer("done")}
    end)

    {id, agent} = start_agent(capabilities: [Blocking])
    :ok = WardrikCore.ask(agent, "first")
    assert_receive {:tool_running, "call-a", tool}

    :ok = WardrikCore.ask(agent, "actually, second")
    send(tool, :release)

    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

    assert [:user, :assistant, :tool, :user, :assistant] =
             agent |> WardrikCore.history() |> Enum.map(& &1.role)
  end

  test "status, history and stop" do
    test = self()

    ReqLLM
    |> expect(:stream_text, fn _, _, _ ->
      send(test, :generating)
      receive do: (:never -> :ok)
    end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent()
    assert :idle = WardrikCore.status(agent)
    assert [] = WardrikCore.history(agent)

    :ok = WardrikCore.ask(agent, "hi")
    assert_receive :generating
    assert :running = WardrikCore.status(agent)

    ref = Process.monitor(agent)
    assert :ok = WardrikCore.stop(agent)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    assert_receive {[:agent, :stop], %{agent_id: ^id}}

    {^id, agent} = start_agent(agent_id: id)

    assert_receive {[:turn, :stop],
                    %{agent_id: ^id, outcome: :ok, messages: [%{role: :assistant}]}}

    assert [:user, :assistant] = agent |> WardrikCore.history() |> Enum.map(& &1.role)
  end

  test "an ask, a park and a resume emit their lifecycle in order" do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(middleware: [ParkTools])
    assert_receive {[:agent, :start], %{agent_id: ^id, state: :idle}}

    :ok = WardrikCore.ask(agent, "hi")

    assert_receive {[:message, :queued],
                    %{agent_id: ^id, message: %{metadata: %{id: message_id}}}}

    assert_receive {[:turn, :start],
                    %{agent_id: ^id, kind: :run, span: span, message_ids: [^message_id]}}

    assert_receive {[:turn, :stop],
                    %{agent_id: ^id, kind: :run, outcome: :park, reason: {:tool_calls, [_]}}}

    :ok = WardrikCore.resume(agent, %{"1" => :approve}, %{by: "maria"})

    assert_receive {[:turn, :start],
                    %{agent_id: ^id, kind: :resume, metadata: %{by: "maria"}, span: ^span}}

    assert_receive {[:turn, :stop], %{agent_id: ^id, kind: :resume, outcome: :ok}}
  end

  test "a turn keeps its metadata across a park and resume" do
    Process.register(self(), WardrikCore.AgentTest)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(middleware: [Trace, ParkTools])
    :ok = WardrikCore.ask(agent, "hi")
    assert_receive {:trace, trace}
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :park}}

    :ok = WardrikCore.resume(agent, %{"1" => :approve})
    assert_receive {:trace, ^trace}
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
  end

  test "ask/3 metadata travels with the message" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent()
    :ok = WardrikCore.ask(agent, "hi", %{from: "jon"})

    assert_receive {[:message, :queued], %{agent_id: ^id, message: %{metadata: %{from: "jon"}}}}
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    assert [%{metadata: %{from: "jon"}}, _answer] = WardrikCore.history(agent)
  end

  test "a turn acts on behalf of whoever asked, and each step says so" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(principal: %Principal{id: "agent:triage"})
    :ok = WardrikCore.ask(agent, "hi", %{principal: %Principal{id: "user:maria"}})

    assert_receive {[:step, :stop],
                    %{
                      agent_id: ^id,
                      step: :generate,
                      attributes: %{
                        "enduser.id" => "user:maria",
                        "wardrik.agent.principal.id" => "agent:triage"
                      }
                    }}
  end

  test "a turn no one asked for acts as the agent itself" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(principal: %Principal{id: "agent:triage"})
    :ok = WardrikCore.ask(agent, "hi")

    assert_receive {[:step, :stop],
                    %{
                      agent_id: ^id,
                      step: :generate,
                      attributes: %{"enduser.id" => "agent:triage"}
                    }}
  end

  test "whereis/1 finds a running agent by id" do
    {id, agent} = start_agent()

    assert ^agent = WardrikCore.whereis(id)
    assert nil == WardrikCore.whereis("no-such-agent")
  end

  test "keeps each conversation apart from its agent, whatever its ids hold" do
    id = "acme/triage %2F/x"
    {^id, agent} = start_agent(agent_id: id)
    {^id, held} = start_agent(agent_id: id, conversation: "C1/1696.1234")

    refute held == agent
    assert ^held = WardrikCore.whereis({id, "C1/1696.1234"})
    assert ^agent = WardrikCore.whereis(id)
    assert nil == WardrikCore.whereis({id, "C1"})
    assert {id, nil} in WardrikCore.list()
    assert {id, "C1/1696.1234"} in WardrikCore.list()
    assert %{agent_id: ^id, conversation: "C1/1696.1234"} = agent_state(held)

    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)
    :ok = WardrikCore.ask(held, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, conversation: "C1/1696.1234"}}

    assert :ok = WardrikCore.delete({id, "C1/1696.1234"})
    assert ^agent = WardrikCore.whereis(id)
  end

  test "start_agent/1 metadata reaches middleware" do
    Process.register(self(), WardrikCore.AgentTest)
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {_id, agent} = start_agent(middleware: [Trace], metadata: %{trace: 42})
    :ok = WardrikCore.ask(agent, "hi")

    assert_receive {:trace, 42}
  end

  test "start_agent/1 rejects options it doesn't know" do
    assert_raise ArgumentError, fn -> start_agent(not_an_option: true) end
  end

  test "configure/2 changes the model for the next turn" do
    expect(ReqLLM, :stream_text, fn "moonshotai:kimi-k3", _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent()
    assert :ok = WardrikCore.configure(agent, model: "moonshotai:kimi-k3", max_rounds: 3)

    :ok = WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    assert %{model: "moonshotai:kimi-k3", context: %{max_rounds: 3}} = agent_state(agent)
  end

  test "configure/2 rejects a bad model or option in the caller" do
    {_id, agent} = start_agent()

    assert_raise ArgumentError, fn -> WardrikCore.configure(agent, model: "nope:nope") end
    assert_raise ArgumentError, fn -> WardrikCore.configure(agent, not_an_option: true) end
    assert :idle = WardrikCore.status(agent)
  end

  test "list/1 includes every saved agent" do
    {id, _agent} = start_agent()

    assert {id, nil} in WardrikCore.list()
  end

  test "private data stays with the agent across turns and restarts" do
    Process.register(self(), WardrikCore.AgentTest)
    stub(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(middleware: [Counter])

    for expected <- [1, 2] do
      :ok = WardrikCore.ask(agent, "hi")
      assert_receive {:turns, ^expected}
      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    end

    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    {^id, agent} = start_agent(agent_id: id, middleware: [Counter])
    :ok = WardrikCore.ask(agent, "hi")
    assert_receive {:turns, 3}
  end

  test "context/1 gives the next turn's context, and a step run through it leaves history alone" do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("hello")} end)
    |> expect(:stream_text, fn _, [_system, _user, _assistant], _ ->
      {:ok, answer("A summary.")}
    end)

    {id, agent} = start_agent()
    WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

    context = WardrikCore.context(agent)
    assert %{agent_id: ^id, capabilities: [Echo]} = context
    assert [:user, :assistant] = Enum.map(context.messages, & &1.role)

    summarizing = %{context | instructions: "Summarise.", tools: []}

    assert {:ok, summarized} =
             WardrikCore.Context.run(summarizing, {:step, "summary"}, &WardrikCore.generate/1)

    assert ReqLLM.Response.text(summarized.response) == "A summary."
    assert [:user, :assistant] = Enum.map(WardrikCore.history(agent), & &1.role)
  end

  test "an unknown cast is ignored" do
    {_id, agent} = start_agent()

    GenServer.cast(agent, :not_a_request)

    assert nil == WardrikCore.parked(agent)
  end

  test "a parked turn is resumed through the public API" do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(middleware: [ParkTools])

    assert {:error, :not_parked} = WardrikCore.resume(agent, %{"1" => :approve})

    WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :park}}
    assert {:tool_calls, [{%{id: "1"}, {:park, :needs_approval}}]} = WardrikCore.parked(agent)

    assert :ok = WardrikCore.resume(agent, %{"nope" => :approve})
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :park}}

    assert :ok = WardrikCore.resume(agent, %{"1" => :approve})

    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

    assert %{state: :idle, parked: nil, in_flight: [], messages: messages} = agent_state(agent)
    assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
    assert nil == WardrikCore.parked(agent)
  end

  test "a call the resumed turn still waits on is answered while the turn runs" do
    Process.register(self(), WardrikCore.AgentTest)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ ->
      {:ok, calling([call("1", "block"), call("2", "echo", %{text: "b"})])}
    end)
    |> expect(:stream_text, fn _, messages, _ ->
      assert [_user, _calls, %{content: [%{text: "released"}]}, %{content: [%{text: denied}]}] =
               messages

      assert denied =~ "Not now."
      {:ok, answer("done")}
    end)

    {id, agent} = start_agent(capabilities: [Echo, Blocking], middleware: [ParkTools])
    WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :park}}

    assert :ok = WardrikCore.resume(agent, %{"1" => :approve})
    assert_receive {:tool_running, "1", tool}

    assert {:tool_calls, [{%{id: "2"}, {:park, :needs_approval}}]} = WardrikCore.parked(agent)
    assert :ok = WardrikCore.resume(agent, %{"2" => {:deny, "Not now."}}, %{by: "maria"})
    assert {:error, :not_parked} = WardrikCore.resume(agent, %{"1" => :approve})
    assert {:error, :not_parked} = WardrikCore.resume(agent, %{"2" => :approve})
    assert {:tool_calls, []} = WardrikCore.parked(agent)

    send(tool, :release)
    assert_receive {[:turn, :stop], %{agent_id: ^id, kind: :resume, outcome: :park}}
    assert_receive {[:turn, :start], %{agent_id: ^id, kind: :resume, metadata: %{by: "maria"}}}
    assert_receive {[:turn, :stop], %{agent_id: ^id, kind: :resume, outcome: :ok}}
  end

  defp start_agent(opts \\ []) do
    {id, opts} =
      Keyword.pop_lazy(opts, :agent_id, fn -> "agent-#{System.unique_integer([:positive])}" end)

    {:ok, agent} =
      [agent_id: id, model: "anthropic:claude-haiku-4-5", capabilities: [Echo]]
      |> Keyword.merge(opts)
      |> WardrikCore.start_agent()

    {id, agent}
  end

  defp agent_state(agent), do: :sys.get_state(agent).user_state
end
