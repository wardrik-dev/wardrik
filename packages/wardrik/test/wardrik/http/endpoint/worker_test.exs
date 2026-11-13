defmodule Wardrik.HTTP.Endpoint.WorkerTest do
  use ExUnit.Case, async: true

  alias Wardrik.HTTP.Test.Worker
  alias Wardrik.Testing.Server

  @lookup %{"name" => "lookup", "inputSchema" => %{"type" => "object"}}

  # Each message crosses a real socket, which a busy runner can take longer than 100ms over.
  @wait 1_000

  setup context do
    name = :"server #{context.test}"
    :ok = Wardrik.HTTP.Test.start(name, ["wrk_shop"])

    http =
      start_supervised!(
        {Wardrik.HTTP.Endpoint,
         server: {Server, name},
         authenticator: {Wardrik.HTTP.Test.Authenticator, []},
         port: 0,
         keepalive: 50}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(http)
    %{name: name, port: port, url: "ws://localhost:#{port}/v1/workers"}
  end

  test "offers what a worker lists through its server, and runs the calls it's sent", context do
    {worker, pid} = connect(context)

    ref = make_ref()

    send(
      pid,
      {Wardrik.Workers, :call, {self(), ref}, "lookup", %{"order" => "A1"}, %{"run" => "r1"}}
    )

    assert_receive {:worker, %{"method" => "tools/call", "id" => id, "params" => params}}, @wait
    assert %{"name" => "lookup", "arguments" => %{"order" => "A1"}} = params

    answer = %{"content" => [%{"type" => "text", "text" => "Shipped."}]}
    Worker.send_message(worker, %{"jsonrpc" => "2.0", "id" => id, "result" => answer})

    assert_receive {^ref, %{"result" => ^answer}}, @wait
  end

  test "tells the worker when a call it runs is stopped", context do
    {_worker, pid} = connect(context)
    call = {self(), make_ref()}

    send(pid, {Wardrik.Workers, :call, call, "lookup", %{}, %{}})
    assert_receive {:worker, %{"method" => "tools/call", "id" => id}}, @wait

    send(pid, {Wardrik.Workers, :cancel, call})

    assert_receive {:worker,
                    %{"method" => "notifications/cancelled", "params" => %{"requestId" => ^id}}},
                   @wait
  end

  test "lists the tools again when the worker says they changed", context do
    {worker, _pid} = connect(context)

    Worker.send_message(worker, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed"
    })

    assert_receive {:worker, %{"method" => "tools/list"}}, @wait
  end

  test "ignores what doesn't read as JSON-RPC, and goes on", context do
    {worker, _pid} = connect(context)

    WebSockex.send_frame(worker, {:text, "not json"})
    WebSockex.send_frame(worker, {:text, "[1, 2]"})
    WebSockex.send_frame(worker, {:binary, <<0, 1>>})
    Worker.send_message(worker, %{"id" => 99, "result" => %{}})
    Worker.send_message(worker, %{"jsonrpc" => "2.0", "id" => "w3", "method" => "ping"})

    assert_receive {:worker, %{"id" => "w3", "result" => %{}}}, @wait
  end

  test "answers what it doesn't handle as a method not found", context do
    {worker, _pid} = connect(context)

    Worker.send_message(worker, %{
      "jsonrpc" => "2.0",
      "id" => "w2",
      "method" => "sampling/createMessage"
    })

    assert_receive {:worker, %{"id" => "w2", "error" => %{"code" => -32_601}}}, @wait
  end

  test "closes the socket once it no longer authenticates", context do
    connect(context)
    Wardrik.HTTP.Test.Authenticator.revoke(context.name, "wrk_shop")

    assert_receive {:worker_closed, {:remote, 1008, "The request no longer authenticates."}},
                   @wait
  end

  test "refuses a socket that doesn't authenticate, and asks one that does to upgrade", context do
    assert {:error, %WebSockex.RequestError{code: 401}} =
             Worker.start(context.url, "wrk_nope", self())

    request = %{name: context.name, secret: "wrk_shop"}
    assert Wardrik.HTTP.Test.request(request, "GET", "/v1/workers").status == 426
  end

  defp connect(context) do
    {:ok, worker} = Worker.start(context.url, "wrk_shop", self())

    assert_receive {:worker, %{"method" => "initialize", "id" => id}}, @wait

    Worker.send_message(worker, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"capabilities" => %{}}
    })

    assert_receive {:worker, %{"method" => "notifications/initialized"}}, @wait
    assert_receive {:worker, %{"method" => "tools/list", "id" => list}}, @wait

    Worker.send_message(worker, %{
      "jsonrpc" => "2.0",
      "id" => list,
      "result" => %{"tools" => [@lookup]}
    })

    assert_receive {:offered, pid, [@lookup]}, @wait
    {worker, pid}
  end
end
