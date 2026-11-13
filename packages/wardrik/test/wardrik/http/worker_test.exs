defmodule Wardrik.HTTP.WorkerTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.HTTP

  alias Wardrik.Test.HTTP.Worker

  setup :set_mimic_global
  setup :start_wardrik

  setup context do
    server = start_supervised!({Wardrik.HTTP, http(context, port: 0, keepalive: 50)})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    shop = Wardrik.Test.HTTP.Authenticator.sign_in(context.wardrik, "acme/@shop")
    %{url: "ws://localhost:#{port}/v1/workers", shop: shop}
  end

  @lookup %{
    "name" => "lookup",
    "description" => "Looks an order up.",
    "inputSchema" => %{"type" => "object", "properties" => %{"order" => %{"type" => "string"}}},
    "annotations" => %{"readOnlyHint" => true}
  }

  test "offers what a worker lists to the agents it serves, and runs their calls on it",
       context do
    worker = connect(context)

    answers([
      calling("call_1", "workers__lookup", %{"order" => "A1"}),
      answer("It shipped.")
    ])

    event_log =
      context.wardrik
      |> Wardrik.Instance.fetch!()
      |> Wardrik.events()

    :ok = Wardrik.EventLog.subscribe(event_log, :all)

    request(context, "PUT", "/v1/agents/acme%2Ftriage", %{
      "model" => "anthropic:claude-haiku-4-5",
      "tools" => ["workers/*"]
    })

    request(context, "POST", "/v1/agents/acme%2Ftriage/messages", %{"content" => "Where's A1?"})

    assert_receive {:worker, %{"method" => "tools/call", "id" => id, "params" => params}}
    assert %{"name" => "lookup", "arguments" => %{"order" => "A1"}} = params
    assert %{"agent" => "acme/triage", "idempotencyKey" => "call_1"} = params["_meta"]

    Worker.send_message(worker, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"content" => [%{"type" => "text", "text" => "Shipped."}]}
    })

    assert_receive {Wardrik.EventLog, _log,
                    %{"type" => "wardrik.tool_call.completed", "data" => %{"status" => "ok"}}}

    assert_receive {Wardrik.EventLog, _log, %{"type" => "wardrik.run.completed"}}
  end

  test "tells the worker when a call it runs is stopped", context do
    connect(context)
    answers([calling("call_1", "workers__lookup", %{"order" => "A1"}), answer("Stopped.")])

    request(context, "PUT", "/v1/agents/acme%2Ftriage", %{
      "model" => "anthropic:claude-haiku-4-5",
      "tools" => ["workers/*"]
    })

    request(context, "POST", "/v1/agents/acme%2Ftriage/messages", %{"content" => "Where's A1?"})
    assert_receive {:worker, %{"method" => "tools/call", "id" => id}}

    assert request(context, "DELETE", "/v1/agents/acme%2Ftriage/calls/call_1").status == 204

    assert_receive {:worker,
                    %{"method" => "notifications/cancelled", "params" => %{"requestId" => ^id}}}
  end

  test "lists the tools again when the worker says they changed", context do
    worker = connect(context)

    Worker.send_message(worker, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed"
    })

    assert_receive {:worker, %{"method" => "tools/list"}}
  end

  test "ignores what doesn't read as JSON-RPC, and goes on", context do
    worker = connect(context)

    WebSockex.send_frame(worker, {:text, "not json"})
    WebSockex.send_frame(worker, {:text, "[1, 2]"})
    WebSockex.send_frame(worker, {:binary, <<0, 1>>})
    Worker.send_message(worker, %{"id" => 99, "result" => %{}})
    Worker.send_message(worker, %{"jsonrpc" => "2.0", "id" => "w3", "method" => "ping"})

    assert_receive {:worker, %{"id" => "w3", "result" => %{}}}
  end

  test "answers what it doesn't handle as a method not found", context do
    worker = connect(context)

    Worker.send_message(worker, %{
      "jsonrpc" => "2.0",
      "id" => "w2",
      "method" => "sampling/createMessage"
    })

    assert_receive {:worker, %{"id" => "w2", "error" => %{"code" => -32_601}}}
  end

  test "closes the socket once it no longer authenticates", context do
    connect(context)

    Wardrik.Test.HTTP.Authenticator.revoke(context.wardrik, context.shop)
    assert_receive {:worker_closed, {:remote, 1008, "The request no longer authenticates."}}
  end

  test "refuses a socket that doesn't authenticate, and asks one that does to upgrade", context do
    assert {:error, %WebSockex.RequestError{code: 401}} =
             Worker.start(context.url, "wrk_nope", self())

    assert request(context, "GET", "/v1/workers").status == 426
    assert request(%{context | secret: "wrk_nope"}, "GET", "/v1/workers").status == 401
  end

  defp connect(context) do
    {:ok, worker} = Worker.start(context.url, context.shop, self())

    assert_receive {:worker, %{"method" => "initialize", "id" => id}}

    Worker.send_message(worker, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"capabilities" => %{}}
    })

    assert_receive {:worker, %{"method" => "notifications/initialized"}}
    assert_receive {:worker, %{"method" => "tools/list", "id" => list}}

    Worker.send_message(worker, %{
      "jsonrpc" => "2.0",
      "id" => list,
      "result" => %{"tools" => [@lookup]}
    })

    Worker.send_message(worker, %{"jsonrpc" => "2.0", "id" => "w1", "method" => "ping"})
    assert_receive {:worker, %{"id" => "w1", "result" => %{}}}

    worker
  end

  defp calling(id, name, arguments),
    do: %ReqLLM.Response{
      id: "resp",
      model: "test",
      context: nil,
      message:
        ReqLLM.Context.assistant("",
          tool_calls: [ReqLLM.ToolCall.new(id, name, JSON.encode!(arguments))]
        )
    }
end
