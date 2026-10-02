defmodule WardrikHTTP.WorkerTest do
  use ExUnit.Case, async: false

  alias Wardrik.Grant
  alias Wardrik.Ledger
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias Wardrik.Test.Calls
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
    {:ok, secret, _token} = Token.create("worker-test", "test/", Grant.actions(), ceiling: [])
    listener = :"worker-#{System.unique_integer([:positive])}"
    start_supervised!({Listener, name: listener, port: 0})
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

    %{port: port, secret: secret, agent: Wardrik.Test.Fleet.key()}
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

  # A worker's tool is gated unless it is read-only, so a call to echo runs
  # where a rule allows it by name.
  defp allowing_echo,
    do: WardrikPolicy.hooks(WardrikPolicy.decode!(%{"allow" => ["workers/echo"]}))

  test "a worker's tool is gated unless every worker offering it marks it read-only", context do
    connect(context, [tool("lookup", %{"readOnlyHint" => true}), tool("refund")])

    refute Workers.gated?(context.agent, "workers__lookup")
    assert Workers.gated?(context.agent, "workers__refund")
    assert Workers.gated?(context.agent, "workers__nothing")
  end

  test "a worker's tools are offered to the agents its token reaches, named for the workers",
       context do
    connect(context, [tool("echo"), tool("not a name!")])

    assert names(Workers.tools(context.agent)) == ["workers__echo"]
    assert Workers.tools("other/agent") == []
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
    agent = context.agent
    "test/" <> name = agent

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

  test "a call for a user's agent says whose it is, however the model called it", context do
    connect(context, [tool("echo")])
    agent = "test/@u_42/assistant-#{System.unique_integer([:positive])}"
    "test/@u_42/" <> name = agent

    Workers.call(agent, "echo", Calls.tool("echo", %{"order" => "o_1", "user" => "u_7"}))

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

  test "a worker's error, and its going away, reach the model as errors", context do
    connect(context, [tool("fail"), tool("leave")])

    assert Workers.call(context.agent, "fail", Calls.tool("fail"))
           |> Calls.result() ==
             {:ok,
              %{
                "ok" => false,
                "error" => %{"code" => "tool_error", "message" => "No such order."}
              }}

    assert {:ok, %{"ok" => false, "error" => %{"code" => "worker_gone", "message" => message}}} =
             Workers.call(context.agent, "leave", Calls.tool("leave"))
             |> Calls.result()

    assert message =~ "may already have done what it does"
  end

  test "a call not answered in time is cancelled", context do
    previous = Application.get_env(:wardrik_http, WardrikHTTP, [])
    Application.put_env(:wardrik_http, WardrikHTTP, Keyword.put(previous, :worker_timeout, 50))
    on_exit(fn -> Application.put_env(:wardrik_http, WardrikHTTP, previous) end)

    connect(context, [tool("hang")])

    assert {:ok, %{"ok" => false, "error" => %{"code" => "timeout"}}} =
             Workers.call(context.agent, "hang", Calls.tool("hang"))
             |> Calls.result()

    assert_receive {:notified, "notifications/cancelled", %{"requestId" => _id}}
  end

  test "a call no worker in reach offers does not run", context do
    connect(
      context,
      [tool("echo")],
      elem(Token.create("elsewhere", "test/only/", Grant.actions(), ceiling: []), 1)
    )

    assert {:ok, %{"ok" => false, "error" => %{"code" => "no_worker"}}} =
             Workers.call(context.agent, "echo", Calls.tool("echo"))
             |> Calls.result()

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

    assert Workers.in_doubt(context.agent, "workers__look") == :rerun
    assert Workers.in_doubt(context.agent, "workers__refund") == :rerun
    assert Workers.in_doubt(context.agent, "workers__send") == :ask
    assert Workers.in_doubt(context.agent, "workers__absent") == :ask
    assert Workers.in_doubt(context.agent, "web_search") == :ask
  end

  test "a worker out of an agent's reach does not decide whether its call runs again", context do
    {:ok, elsewhere, _token} = Token.create("elsewhere", "other/", Grant.actions(), ceiling: [])
    connect(context, [tool("refund", %{"idempotentHint" => true})], elsewhere)
    connect(context, [tool("refund")])

    assert Workers.in_doubt(context.agent, "workers__refund") == :ask
    assert Workers.in_doubt("other/agent", "workers__refund") == :rerun
  end

  test "a tool runs again only where every worker in reach offering it says it may", context do
    connect(context, [tool("refund", %{"idempotentHint" => true})])
    assert Workers.in_doubt(context.agent, "workers__refund") == :rerun

    connect(context, [tool("refund")])
    assert Workers.in_doubt(context.agent, "workers__refund") == :ask
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
    {:ok, secret, _token} = Token.create("reader", "test/", [:read])

    assert {:error, %WebSockex.RequestError{code: 403}} =
             FakeWorker.start_link(port, secret, self(), [tool("echo")])
  end

  test "a worker's socket closes when its token is revoked",
       context do
    {:ok, secret, token} = Token.create("revoked", "test/", Grant.actions(), ceiling: [])
    worker = connect(context, [tool("echo")], secret)
    monitor = Process.monitor(worker)

    :ok = Token.revoke(token.id)

    assert_receive {:disconnected, {:remote, 1008, "The token was revoked."}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
  end

  test "a request that is not a WebSocket is told to upgrade", %{port: port, secret: secret} do
    assert {:ok, %{status: 426} = response} =
             Req.get("http://127.0.0.1:#{port}/v1/workers", auth: {:bearer, secret}, retry: false)

    assert Req.Response.get_header(response, "upgrade") == ["websocket"]
    assert response.body["error"]["type"] == "upgrade_required"
  end

  test "a worker's answers are content from outside, unless the deployment trusts its workers" do
    assert Workers.outside_content?("test/triage", "workers__echo")

    previous = Application.get_env(:wardrik_http, WardrikHTTP)

    Application.put_env(
      :wardrik_http,
      WardrikHTTP,
      Keyword.put(previous || [], :trusted_workers, true)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wardrik_http, WardrikHTTP, previous),
        else: Application.delete_env(:wardrik_http, WardrikHTTP)
    end)

    refute Workers.outside_content?("test/triage", "workers__echo")
  end
end
