defmodule WardrikMCP.SupervisorTest do
  use WardrikMCP.Test.Case, async: false

  alias Wardrik.Resource
  alias WardrikMCP.Server

  test "lists the servers it is connecting to", %{key: key} do
    assert [%Server{key: ^key}] = WardrikMCP.Supervisor.servers()
  end

  test "connects to one more while it runs, and to the same one twice safely", %{key: key} do
    second = Resource.parse!("deployment/server/#{Resource.basename(key)}_more")
    server = Server.new(second, stub_options())

    assert {:ok, pid} = WardrikMCP.Supervisor.connect(server)
    assert {:ok, ^pid} = WardrikMCP.Supervisor.connect(server)
    assert await_tools(second) != []
  end

  test "a server that is stopped can be started again", %{key: key} do
    assert :ok = WardrikMCP.disconnect(key)
    assert {:error, :not_found} = WardrikMCP.disconnect(key)

    assert {:ok, _pid} = WardrikMCP.Supervisor.connect(Server.new(key, stub_options()))
    assert await_tools(key) != []
  end

  test "a per-principal connection is started and stopped on its own", %{key: key} do
    {:ok, server} = {:ok, %{WardrikMCP.Connection.offer(key).server | credential: "x"}}

    assert {:ok, pid} = WardrikMCP.Supervisor.connect(server, "someone", server.transport)
    assert {:ok, ^pid} = WardrikMCP.Supervisor.connect(server, "someone", server.transport)
    assert WardrikMCP.Connection.running?(key, "someone")

    GenServer.stop(pid)
    refute WardrikMCP.Connection.running?(key, "someone")
  end
end
