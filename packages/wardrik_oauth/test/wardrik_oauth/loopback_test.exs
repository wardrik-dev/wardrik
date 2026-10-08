defmodule WardrikOAuth.LoopbackTest do
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.Calls
  alias WardrikOAuth.Loopback
  alias WardrikOAuth.Pending

  setup %{owner: owner} do
    # The callback is served from a process of the listener's own, so the stub
    # cannot belong to this test alone.
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    port = 4600 + System.unique_integer([:positive, :monotonic])
    start_supervised!({WardrikOAuth.Supervisor, port: port})
    :ok = configure([])

    %{port: port, owner: owner}
  end

  # Starts a flow for `owner` against a stub server answering with `server`.
  defp flow(%{port: port, owner: owner}, server \\ []) do
    stub_server([cimd: true] ++ server)

    configure(
      providers: [github: [resource: resource(), scopes: ~w(repo)]],
      redirect: [port: port, open: false]
    )

    id = AgentID.new!("a", org: "acme", user: owner)
    scope = Config.new() |> Scope.root(id, credentials: WardrikVault)

    {:error, {:authorization_required, %{url: url}, _owner}} =
      Credential.resolve(Calls.tool("tool", %{}, scope), "github")

    %{scope: scope, url: url, state: state_of(url)}
  end

  defp get(port, target) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{target} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n"
      )

    response = read_all(socket, "")
    :gen_tcp.close(socket)

    response
  end

  defp read_all(socket, read) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, more} -> read_all(socket, read <> more)
      {:error, :closed} -> read
    end
  end

  test "a browser coming back with a code finishes the flow, at the provider's own path",
       context do
    %{url: url, state: state, scope: scope} = flow(context)
    assert params_of(url)["redirect_uri"] == "http://127.0.0.1:#{context.port}/callback/github"

    response = get(context.port, "/callback/github?code=the-code&state=#{state}")

    assert response =~ "200 OK"
    assert response =~ "github is connected"

    assert {:ok, credential} =
             Credential.resolve(Calls.tool("tool", %{}, scope), "github")

    assert Credential.reveal(credential) == "at_first"
  end

  test "a code that comes back to another provider's path finishes nothing", context do
    %{state: state} = flow(context)

    assert get(context.port, "/callback/linear?code=the-code&state=#{state}") =~
             "400 Bad Request"

    assert {:ok, _flight} = Pending.under_way("github", {"acme", context.owner})

    assert get(context.port, "/callback/github?code=the-code&state=#{state}") =~ "200 OK"
  end

  test "a callback naming another issuer finishes nothing", context do
    %{state: state} = flow(context)

    assert get(
             context.port,
             "/callback/github?code=c&state=#{state}&iss=https%3A%2F%2Fevil.example.com"
           ) =~ "400 Bad Request"

    assert get(
             context.port,
             "/callback/github?code=c&state=#{state}&iss=https%3A%2F%2Fauth.example.com"
           ) =~ "200 OK"
  end

  test "a callback without iss, from an issuer that says it sends one, finishes nothing",
       context do
    %{state: state} = flow(context, iss: true)

    assert get(context.port, "/callback/github?code=c&state=#{state}") =~ "400 Bad Request"

    assert get(
             context.port,
             "/callback/github?code=c&state=#{state}&iss=https%3A%2F%2Fauth.example.com"
           ) =~ "200 OK"
  end

  test "the listener keeps answering after one callback", context do
    %{state: state} = flow(context)

    get(context.port, "/callback/github?code=the-code&state=#{state}")

    assert get(context.port, "/nothing-here") =~ "404 Not Found"
  end

  test "a callback the user refused says so, escaped, and stores nothing", context do
    flow(context)

    response =
      get(context.port, "/callback/github?error=access_denied&error_description=%3Cscript%3E")

    assert response =~ "400 Bad Request"
    assert response =~ "access_denied: &lt;script&gt;"
    refute response =~ "<script>"
    refute WardrikOAuth.connected?("github", {"acme", context.owner})
  end

  test "a callback with no code is refused", %{port: port} do
    assert get(port, "/callback/github") =~ "400 Bad Request"
  end

  test "a path that is not a callback is not served", %{port: port} do
    assert get(port, "/") =~ "404 Not Found"
    assert get(port, "/callback") =~ "404 Not Found"
  end

  test "a port another process holds is listened on once it is free" do
    {:ok, held} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(held)

    {listener, log} =
      ExUnit.CaptureLog.with_log(fn ->
        {:ok, listener} = GenServer.start_link(Loopback, port: port, retry: :timer.hours(1))
        listener
      end)

    assert log =~ "OAuth loopback could not listen on #{port}"
    assert :error = Loopback.listening(listener)

    :ok = :gen_tcp.close(held)
    send(listener, :listen)

    assert {:ok, {{127, 0, 0, 1}, ^port}} = Loopback.listening(listener)
    assert get(port, "/") =~ "404 Not Found"
  end

  test "it listens on loopback only", %{port: port} do
    assert {:ok, {{127, 0, 0, 1}, ^port}} = Loopback.listening()
  end
end
