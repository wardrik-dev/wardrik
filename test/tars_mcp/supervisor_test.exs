defmodule TarsMCP.SupervisorTest do
  use TarsMCP.Case, async: false

  alias TarsMCP.Server

  test "lists the servers it is connecting to", %{ref: ref} do
    assert [%Server{ref: ^ref}] = TarsMCP.Supervisor.servers()
  end

  test "connects to one more while it runs, and to the same one twice safely", %{ref: ref} do
    second = :"#{ref}_more"
    server = Server.new(second, stub_options())

    assert {:ok, pid} = TarsMCP.Supervisor.connect(server)
    assert {:ok, ^pid} = TarsMCP.Supervisor.connect(server)
    assert await_tools(second) != []
  end

  test "a server that is stopped can be started again", %{ref: ref} do
    assert :ok = TarsMCP.disconnect(ref)
    assert {:error, :not_found} = TarsMCP.disconnect(ref)

    assert {:ok, _pid} = TarsMCP.Supervisor.connect(Server.new(ref, stub_options()))
    assert await_tools(ref) != []
  end

  test "a per-principal connection is started and stopped on its own", %{ref: ref} do
    {:ok, server} = {:ok, %{TarsMCP.Connection.offer(ref).server | credential: {:user, "x"}}}

    assert {:ok, pid} = TarsMCP.Supervisor.connect(server, "someone", server.transport)
    assert {:ok, ^pid} = TarsMCP.Supervisor.connect(server, "someone", server.transport)
    assert TarsMCP.Connection.running?(ref, "someone")

    GenServer.stop(pid)
    refute TarsMCP.Connection.running?(ref, "someone")
  end
end
