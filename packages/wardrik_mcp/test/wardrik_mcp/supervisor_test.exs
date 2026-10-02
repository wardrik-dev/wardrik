defmodule WardrikMCP.SupervisorTest do
  use WardrikMCP.Case, async: false

  alias WardrikMCP.Server

  test "lists the servers it is connecting to", %{ref: ref} do
    assert [%Server{ref: ^ref}] = WardrikMCP.Supervisor.servers()
  end

  test "connects to one more while it runs, and to the same one twice safely", %{ref: ref} do
    second = :"#{ref}_more"
    server = Server.new(second, stub_options())

    assert {:ok, pid} = WardrikMCP.Supervisor.connect(server)
    assert {:ok, ^pid} = WardrikMCP.Supervisor.connect(server)
    assert await_tools(second) != []
  end

  test "a server that is stopped can be started again", %{ref: ref} do
    assert :ok = WardrikMCP.disconnect(ref)
    assert {:error, :not_found} = WardrikMCP.disconnect(ref)

    assert {:ok, _pid} = WardrikMCP.Supervisor.connect(Server.new(ref, stub_options()))
    assert await_tools(ref) != []
  end

  test "a per-principal connection is started and stopped on its own", %{ref: ref} do
    {:ok, server} = {:ok, %{WardrikMCP.Connection.offer(ref).server | credential: "x"}}

    assert {:ok, pid} = WardrikMCP.Supervisor.connect(server, "someone", server.transport)
    assert {:ok, ^pid} = WardrikMCP.Supervisor.connect(server, "someone", server.transport)
    assert WardrikMCP.Connection.running?(ref, "someone")

    GenServer.stop(pid)
    refute WardrikMCP.Connection.running?(ref, "someone")
  end
end
