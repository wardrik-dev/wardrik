defmodule TarsOAuth.LoopbackTest do
  use TarsOAuth.Case, async: false

  alias Tars.Credential
  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Test.Calls

  setup %{owner: owner} do
    # The callback is served from a process of the listener's own, so the stub
    # cannot belong to this test alone.
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    port = 4600 + System.unique_integer([:positive, :monotonic])
    start_supervised!({TarsOAuth.Supervisor, port: port})

    stub_server(cimd: true)

    configure(
      providers: [github: [resource: resource(), scopes: ~w(repo)]],
      redirect: [uri: "http://127.0.0.1:#{port}/callback"]
    )

    scope = Config.new() |> Scope.root("acme/#{owner}/a", user: owner, credentials: TarsOAuth)

    {:error, {:authorization_required, url}} =
      Credential.resolve(Calls.tool("tool", %{}, scope), {:user, "github"})

    %{port: port, scope: scope, url: url}
  end

  defp get(port, target) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)

    :ok = :gen_tcp.send(socket, "GET #{target} HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    response
  end

  test "a browser coming back with a code finishes the flow", context do
    %{port: port, scope: scope, url: url} = context

    response = get(port, "/callback?code=the-code&state=#{state_of(url)}")

    assert response =~ "200 OK"
    assert response =~ "github is connected"

    assert {:ok, credential} =
             Credential.resolve(Calls.tool("tool", %{}, scope), {:user, "github"})

    assert Credential.reveal(credential) == "at_first"
  end

  test "the listener keeps answering after one callback", context do
    %{port: port, url: url} = context

    get(port, "/callback?code=the-code&state=#{state_of(url)}")

    assert get(port, "/nothing-here") =~ "404 Not Found"
  end

  test "a callback the user refused says so and stores nothing", context do
    %{port: port, scope: scope} = context

    response = get(port, "/callback?error=access_denied&error_description=nope")

    assert response =~ "400 Bad Request"
    assert response =~ "access_denied"
    refute TarsOAuth.connected?("github", scope.user)
  end

  test "a callback with no code is refused", %{port: port} do
    assert get(port, "/callback") =~ "400 Bad Request"
  end

  test "a path that is not the callback is not served", %{port: port} do
    assert get(port, "/") =~ "404 Not Found"
  end

  test "a port another process holds is listened on once it is free" do
    {:ok, held} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(held)

    {listener, log} =
      ExUnit.CaptureLog.with_log(fn ->
        {:ok, listener} =
          GenServer.start_link(TarsOAuth.Loopback, port: port, retry: :timer.hours(1))

        listener
      end)

    assert log =~ "OAuth loopback could not listen on #{port}: :eaddrinuse"
    assert %{socket: nil} = :sys.get_state(listener)

    :ok = :gen_tcp.close(held)
    send(listener, :listen)

    assert %{socket: socket} = :sys.get_state(listener)
    assert :inet.sockname(socket) == {:ok, {{127, 0, 0, 1}, port}}
    assert get(port, "/") =~ "404 Not Found"
  end

  test "it listens on loopback only", %{port: port} do
    %{socket: socket} = :sys.get_state(TarsOAuth.Loopback)

    assert :inet.sockname(socket) == {:ok, {{127, 0, 0, 1}, port}}
  end
end
