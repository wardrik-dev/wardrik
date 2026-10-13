defmodule WardrikHTTP.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Grant
  alias Wardrik.Ledger
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias WardrikHTTP.Listener
  alias WardrikHTTP.Token
  alias WardrikHTTP.Workers

  # A tool worker, as the SDK will be one: it answers Wardrik's MCP requests, and
  # tells the test what it was sent.
  defmodule FakeWorker do
    @moduledoc false
    use WebSockex

    def start_link(port, secret, test, tools) do
      WebSockex.start_link(
        "ws://127.0.0.1:#{port}/v1/workers",
        __MODULE__,
        %{test: test, tools: tools},
        extra_headers: [{"authorization", "Bearer " <> secret}]
      )
    end

    @impl true
    def handle_frame({:text, text}, state), do: text |> JSON.decode!() |> answer(state)

    @impl true
    def handle_info({:tools, tools}, state) do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      {:reply, {:text, JSON.encode!(notification)}, %{state | tools: tools}}
    end

    def handle_info({:send, message}, state), do: {:reply, {:text, JSON.encode!(message)}, state}

    @impl true
    def handle_disconnect(%{reason: reason}, state) do
      send(state.test, {:disconnected, reason})
      {:ok, state}
    end

    defp answer(%{"method" => "initialize", "id" => id}, state) do
      reply(id, state, %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{"listChanged" => true}},
        "serverInfo" => %{"name" => "fake", "version" => "0"}
      })
    end

    defp answer(%{"method" => "tools/list", "id" => id}, state),
      do: reply(id, state, %{"tools" => state.tools})

    defp answer(%{"method" => "tools/call", "id" => id, "params" => params}, state) do
      send(state.test, {:called, params})

      case params["name"] do
        "echo" ->
          reply(id, state, %{
            "content" => [%{"type" => "text", "text" => "Echoed."}],
            "structuredContent" => params["arguments"]
          })

        "priced" ->
          reply(id, state, %{
            "content" => [%{"type" => "text", "text" => "Found."}],
            "structuredContent" => %{"found" => true},
            "_meta" => %{"costUsd" => 0.002}
          })

        "declined" ->
          reply(id, state, %{
            "isError" => true,
            "content" => [%{"type" => "text", "text" => "Declined."}],
            "_meta" => %{"costUsd" => 0.25}
          })

        "fail" ->
          reply(id, state, %{
            "isError" => true,
            "content" => [%{"type" => "text", "text" => "No such order."}]
          })

        "hang" ->
          {:ok, state}

        "leave" ->
          {:close, state}
      end
    end

    defp answer(%{"method" => method} = message, state) do
      send(state.test, {:notified, method, message["params"]})
      {:ok, state}
    end

    defp answer(response, state) do
      send(state.test, {:answered, response})
      {:ok, state}
    end

    defp reply(id, state, result),
      do:
        {:reply, {:text, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})},
         state}
  end

  setup do
    {:ok, secret, _token} =
      Token.create("worker-test", Prefix.parse!("test/"), Grant.actions(), ceiling: [])

    listener = :"worker-#{System.unique_integer([:positive])}"
    start_supervised!({Listener, name: listener, port: 0, host: Wardrik.Host.new()})
    {:ok, port} = Listener.port(listener)

    test = self()
    handler = "worker-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:wardrik, :workers, :listed],
      fn _event, _measurements, meta, _config ->
        send(test, {:listed, meta.worker, meta.tools})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{port: port, secret: secret, agent: Wardrik.Test.Fleet.id()}
  end

  # The group of workers started again with `opts` for this test, and as the
  # suite started it after.
  defp workers(opts) do
    restart_workers(opts)
    on_exit(fn -> restart_workers([]) end)
  end

  defp restart_workers(opts) do
    :ok = Supervisor.terminate_child(Wardrik.Test.Supervisor, Workers)
    :ok = Supervisor.delete_child(Wardrik.Test.Supervisor, Workers)
    {:ok, _pid} = Supervisor.start_child(Wardrik.Test.Supervisor, {Workers, opts})
  end

  # A worker connected with `secret`, once Wardrik has offered what it listed.
  defp connect(%{port: port} = context, tools, secret \\ nil) do
    worker =
      start_supervised!(%{
        id: make_ref(),
        start: {FakeWorker, :start_link, [port, secret || context.secret, self(), tools]},
        restart: :temporary
      })

    assert_receive {:listed, _socket, _names}
    worker
  end

  defp tool(name, annotations \\ %{}) do
    %{
      "name" => name,
      "description" => "Does #{name}.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"order" => %{"type" => "string"}}
      },
      "annotations" => annotations
    }
  end

  defp names(tools), do: Enum.map(tools, & &1.name)

  defp annotations(agent, name), do: Wardrik.Tool.annotations({Workers, agent}, name)

  # The context a call to a worker's tool is handed, for the agent under `key`.
  defp handed(id), do: Wardrik.Test.context(Wardrik.Test.scope(id: id))

  # A worker's tool is gated unless it is read-only, so a call to echo runs
  # where a rule allows it by name.
  defp allowing_echo,
    do: [Wardrik.Hook.new("rules", Wardrik.Test.Tools.Rules, allow: ["workers__echo"])]

  test "a worker's tool is gated unless every worker offering it marks it read-only", context do
    connect(context, [tool("lookup", %{"readOnlyHint" => true}), tool("refund")])

    refute annotations(context.agent, "workers__lookup").gated
    assert annotations(context.agent, "workers__refund").gated
    assert annotations(context.agent, "workers__nothing").gated
  end

  test "a worker's tools are offered to the agents its token reaches, named for the workers",
       context do
    connect(context, [tool("echo"), tool("not a name!")])

    assert names(Workers.tools(context.agent)) == ["workers__echo"]
    assert Workers.tools(Wardrik.AgentID.parse!("other/agent")) == []
  end

  test "a call reaches a worker with its agent, its run and its idempotency key, and is answered with what it returned",
       context do
    connect(context, [tool("echo")])

    scope =
      [tools: [{Workers, context.agent}]]
      |> Config.new()
      |> Scope.root(context.agent, name: "turn", ledger: Ledger.Store, hooks: allowing_echo())

    call = %{id: "call_1", name: "workers__echo", arguments: %{"order" => "o_1"}}

    assert %Wardrik.Call{state: :done} = ToolRunner.execute(call, scope)

    key = Ledger.idempotency_key(scope, call)
    run = scope.source.trace.trace_id
    agent = to_string(context.agent)
    name = context.agent.name

    assert_receive {:called,
                    %{
                      "name" => "echo",
                      "arguments" => %{"order" => "o_1"},
                      "_meta" => %{
                        "agent" => %{"key" => ^agent, "org" => "test", "name" => ^name} = whose,
                        "run" => ^run,
                        "idempotencyKey" => ^key
                      }
                    }}

    refute Map.has_key?(whose, "user")

    assert {:ok, %Ledger.Entry{result: {:ok, %{"ok" => true, "result" => %{"order" => "o_1"}}}}} =
             Ledger.fetch(Ledger.Store, Ledger.key(scope, call))
  end

  test "a call is answered with what its worker said it cost", context do
    connect(context, [tool("priced"), tool("echo"), tool("declined")])

    assert {:ok, %{"ok" => true, "result" => %{"found" => true}}, opts} =
             Workers.call(context.agent, "priced", %{}, handed(context.agent))

    assert opts[:cost] == 0.002
    assert opts[:served_by]

    assert {:ok, %{"ok" => true}, opts} =
             Workers.call(context.agent, "echo", %{"order" => "o_1"}, handed(context.agent))

    refute Keyword.has_key?(opts, :cost)

    assert {:ok, %{"ok" => false}, opts} =
             Workers.call(context.agent, "declined", %{}, handed(context.agent))

    assert opts[:cost] == 0.25
  end

  test "a call for a user's agent says whose it is, however the model called it", context do
    connect(context, [tool("echo")])

    id =
      Wardrik.AgentID.new!("assistant-#{System.unique_integer([:positive])}",
        org: "test",
        user: "u_42"
      )

    {agent, name} = {to_string(id), id.name}

    Workers.call(id, "echo", %{"order" => "o_1", "user" => "u_7"}, handed(id))

    assert_receive {:called,
                    %{
                      "arguments" => %{"user" => "u_7"},
                      "_meta" => %{
                        "agent" => %{
                          "key" => ^agent,
                          "org" => "test",
                          "user" => "u_42",
                          "name" => ^name
                        }
                      }
                    }}
  end

  test "a worker's error reaches the model as an error, naming the token that served it",
       context do
    connect(context, [tool("fail")])

    assert {:ok,
            %{
              "ok" => false,
              "error" => %{"code" => "tool_error", "message" => "No such order."}
            }, served_by: %{id: _id, name: "worker-test"}} =
             Workers.call(context.agent, "fail", %{}, handed(context.agent))
  end

  test "a worker going away before it answers leaves its call in doubt", context do
    connect(context, [tool("leave")])

    assert {:in_doubt, "The worker running leave went away before it answered.",
            served_by: %{name: "worker-test"}} =
             Workers.call(context.agent, "leave", %{}, handed(context.agent))
  end

  test "a call not answered in time is cancelled, and left in doubt", context do
    workers(timeout: 50)
    connect(context, [tool("hang")])

    assert {:in_doubt, "hang did not answer in time.", served_by: _served} =
             Workers.call(context.agent, "hang", %{}, handed(context.agent))

    assert_receive {:notified, "notifications/cancelled",
                    %{"requestId" => _id, "reason" => "The call was not answered in time."}}
  end

  test "a call whose caller is stopped is cancelled at its worker", context do
    connect(context, [tool("hang")])
    test = self()

    {:ok, caller} =
      Task.start(fn ->
        Workers.call(context.agent, "hang", %{}, handed(context.agent))
        send(test, :answered)
      end)

    assert_receive {:called, %{"name" => "hang"}}
    Process.exit(caller, :kill)

    assert_receive {:notified, "notifications/cancelled", %{"reason" => "The call was stopped."}}
    refute_received :answered
  end

  test "a worker lost mid-call leaves the call waiting on a person, keeping its claim",
       context do
    connect(context, [tool("leave")])

    scope =
      [tools: [{Workers, context.agent}]]
      |> Config.new()
      |> Scope.root(context.agent,
        name: "turn",
        ledger: Ledger.Store,
        hooks: [Wardrik.Hook.new("rules", Wardrik.Test.Tools.Rules, allow: ["workers__leave"])]
      )

    call = %{id: "call_1", name: "workers__leave", arguments: %{}}

    assert %Wardrik.Call{state: :waiting, asks: [%Wardrik.Call.Ask{by: :doubt, prompt: prompt}]} =
             ToolRunner.execute(call, scope)

    assert prompt =~ "workers__leave may already have done what it does."
    assert prompt =~ "The worker running leave went away before it answered."

    assert {:ok, %Ledger.Entry{result: nil}} =
             Ledger.fetch(Ledger.Store, Ledger.key(scope, call))
  end

  test "a call run again in doubt with no worker to run it stays in doubt", context do
    in_doubt = %{handed(context.agent) | in_doubt: true}

    assert {:in_doubt, "No worker offers echo now to run it again."} =
             Workers.call(context.agent, "echo", %{}, in_doubt)
  end

  test "a tool is bound to the token whose worker offered it first", context do
    connect(context, [tool("echo")])

    {:ok, second, _token} =
      Token.create("second", Prefix.parse!("test/"), Grant.actions(), ceiling: [])

    log =
      capture_log(fn -> connect(context, [tool("echo", %{"readOnlyHint" => true})], second) end)

    assert log =~ "under second offers echo, which worker-test offers too"
    assert annotations(context.agent, "workers__echo").gated

    for _call <- 1..5 do
      assert {:ok, _result, served_by: %{name: "worker-test"}} =
               Workers.call(context.agent, "echo", %{}, handed(context.agent))
    end
  end

  test "a call no worker in reach offers does not run", context do
    connect(
      context,
      [tool("echo")],
      elem(
        Token.create("elsewhere", Prefix.parse!("test/only/"), Grant.actions(), ceiling: []),
        1
      )
    )

    assert {:ok, %{"ok" => false, "error" => %{"code" => "no_worker"}}} =
             Workers.call(context.agent, "echo", %{}, handed(context.agent))

    refute_received {:called, _params}
  end

  test "a worker is listed again when its tools change", context do
    worker = connect(context, [tool("echo")])

    send(worker, {:tools, [tool("echo"), tool("refund")]})

    assert_receive {:listed, _socket, ["echo", "refund"]}
    assert names(Workers.tools(context.agent)) == ["workers__echo", "workers__refund"]
  end

  test "a tool marked read-only or idempotent may run again, and no other", context do
    connect(context, [
      tool("look", %{"readOnlyHint" => true}),
      tool("refund", %{"idempotentHint" => true}),
      tool("send")
    ])

    assert annotations(context.agent, "workers__look").in_doubt == :rerun
    assert annotations(context.agent, "workers__refund").in_doubt == :rerun
    assert annotations(context.agent, "workers__send").in_doubt == :ask
    assert annotations(context.agent, "workers__absent").in_doubt == :ask
    assert annotations(context.agent, "web_search").in_doubt == :ask
  end

  test "a worker out of an agent's reach does not decide whether its call runs again", context do
    {:ok, elsewhere, _token} =
      Token.create("elsewhere", Prefix.parse!("other/"), Grant.actions(), ceiling: [])

    connect(context, [tool("refund", %{"idempotentHint" => true})], elsewhere)
    connect(context, [tool("refund")])

    assert annotations(context.agent, "workers__refund").in_doubt == :ask

    assert annotations(Wardrik.AgentID.parse!("other/agent"), "workers__refund").in_doubt ==
             :rerun
  end

  test "a tool runs again only where every worker in reach offering it says it may", context do
    connect(context, [tool("refund", %{"idempotentHint" => true})])
    assert annotations(context.agent, "workers__refund").in_doubt == :rerun

    connect(context, [tool("refund")])
    assert annotations(context.agent, "workers__refund").in_doubt == :ask
  end

  test "a call that began before its agent was lost runs again, under its key, on an idempotent tool",
       context do
    connect(context, [tool("echo", %{"idempotentHint" => true})])

    scope =
      [tools: [{Workers, context.agent}]]
      |> Config.new()
      |> Scope.root(context.agent, name: "turn", ledger: Ledger.Store, hooks: allowing_echo())

    call = %{id: "call_1", name: "workers__echo", arguments: %{"order" => "o_1"}}
    :ok = Ledger.claim(Ledger.Store, Ledger.key(scope, call), call)

    assert %Wardrik.Call{state: :done} = ToolRunner.execute(call, scope)

    key = Ledger.idempotency_key(scope, call)
    assert_receive {:called, %{"_meta" => %{"idempotencyKey" => ^key}}}
  end

  test "a worker's ping is answered, and a method Wardrik does not have is refused", context do
    worker = connect(context, [tool("echo")])

    send(worker, {:send, %{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"}})
    assert_receive {:answered, %{"id" => 7, "result" => %{}}}

    send(worker, {:send, %{"jsonrpc" => "2.0", "id" => 8, "method" => "sampling/createMessage"}})
    assert_receive {:answered, %{"id" => 8, "error" => %{"code" => -32_601}}}
  end

  test "a token that may not serve is refused the socket", %{port: port} do
    {:ok, secret, _token} =
      Token.create("reader", Prefix.parse!("test/"), [:read])

    assert {:error, %WebSockex.RequestError{code: 403}} =
             FakeWorker.start_link(port, secret, self(), [tool("echo")])
  end

  test "a worker's socket closes when its token is revoked",
       context do
    {:ok, secret, token} =
      Token.create("revoked", Prefix.parse!("test/"), Grant.actions(), ceiling: [])

    worker = connect(context, [tool("echo")], secret)
    monitor = Process.monitor(worker)

    :ok = Token.revoke(token.id)

    assert_receive {:disconnected, {:remote, 1008, "The credential was revoked."}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
  end

  test "a request that is not a WebSocket is told to upgrade", %{port: port, secret: secret} do
    assert {:ok, %{status: 426} = response} =
             Req.get("http://127.0.0.1:#{port}/v1/workers", auth: {:bearer, secret}, retry: false)

    assert Req.Response.get_header(response, "upgrade") == ["websocket"]
    assert response.body["error"]["type"] == "upgrade_required"
  end

  test "a worker's answers are content from outside, unless the deployment trusts its workers" do
    assert annotations(Wardrik.AgentID.parse!("test/triage"), "workers__echo").labels == [
             "outside"
           ]

    workers(trusted: true)

    assert annotations(Wardrik.AgentID.parse!("test/triage"), "workers__echo").labels == []
  end
end
