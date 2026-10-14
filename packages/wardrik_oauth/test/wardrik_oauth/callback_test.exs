defmodule WardrikOAuth.CallbackTest do
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.Calls
  alias WardrikOAuth.Callback
  alias WardrikOAuth.Pending

  setup %{owner: owner} do
    # The callback is served from a process of the listener's own, so the stub
    # cannot belong to this test alone.
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    port = 4600 + System.unique_integer([:positive, :monotonic])
    serve(port, [])

    %{port: port, owner: owner}
  end

  # Starts a flow for `owner` against a stub server answering with `server`,
  # under the redirect settings `redirect`.
  defp flow(%{port: port, owner: owner}, server \\ [], redirect \\ []) do
    stub_server([cimd: true] ++ server)
    if redirect != [], do: serve(port, redirect)

    id = AgentID.new!("a", org: "acme", user: owner)
    scope = Config.new() |> Scope.root(id, host: host())

    {:error, {:authorization_required, %{url: url}, _owner}} =
      Credential.resolve(Calls.tool("tool", %{}, scope), "github")

    %{scope: scope, url: url, state: state_of(url)}
  end

  # The callback answers under the settings it was started with, so it is
  # started again with the redirect a test names.
  defp serve(port, redirect) do
    configure(
      providers: [github: [resource: resource(), scopes: ~w(repo)]],
      redirect: [port: port, open: false] ++ redirect
    )

    _ = stop_supervised(WardrikOAuth.Supervisor)
    start_supervised!({WardrikOAuth.Supervisor, oauth: oauth(), port: port})
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
             "404 Not Found"

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
    refute WardrikOAuth.connected?(vault(), "github", {"acme", context.owner})
  end

  test "a callback with no code is refused", context do
    flow(context)
    assert get(context.port, "/callback/github") =~ "400 Bad Request"
  end

  test "serves the redirect URL's own path, for a front that passes requests on as they came",
       context do
    %{url: url, state: state} = flow(context, [], url: "https://agents.example.com/oauth/")
    assert params_of(url)["redirect_uri"] == "https://agents.example.com/oauth/callback/github"
    refute Callback.loopback?(oauth())

    assert get(context.port, "/callback/github?code=the-code&state=#{state}") =~ "404 Not Found"

    assert get(context.port, "/oauth/callback/github?code=the-code&state=#{state}") =~
             "200 OK"
  end

  test "every page is kept from caches, referrers and frames, and loads nothing", context do
    flow(context)

    for response <- [get(context.port, "/callback/github"), get(context.port, "/elsewhere")] do
      assert response =~ "cache-control: no-store"
      assert response =~ "referrer-policy: no-referrer"
      assert response =~ "content-security-policy: default-src 'none'"
      assert response =~ "x-frame-options: DENY"
    end
  end

  test "check answers with the nonce it was sent, so the URL can be shown to reach it",
       %{port: port} do
    configure(redirect: [port: port])
    assert get(port, "/check?nonce=abc-1") =~ "wardrik abc-1"
    assert get(port, "/check?nonce=%3Cscript%3E") =~ "400 Bad Request"
    assert get(port, "/check") =~ "400 Bad Request"

    assert Callback.check("http://127.0.0.1:#{port}/") == :ok

    {:ok, other} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed} = :inet.port(other)
    :ok = :gen_tcp.close(other)
    assert {:error, "http://127.0.0.1:" <> _} = Callback.check("http://127.0.0.1:#{closed}")
  end

  test "a URL on loopback is this machine's, and opens the browser here" do
    configure(redirect: [url: "http://localhost:4599"])
    assert Callback.loopback?(oauth())
    assert Callback.redirect_uri(oauth(), "github") == "http://localhost:4599/callback/github"

    configure(redirect: [port: 4700])
    assert Callback.loopback?(oauth())
    assert Callback.url(oauth()) == "http://127.0.0.1:4700"
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
        {:ok, listener} =
          GenServer.start_link(Callback, oauth: oauth(), port: port, retry: :timer.hours(1))

        listener
      end)

    assert log =~ "The OAuth callback could not listen on #{port}"
    assert :error = Callback.listening(listener)

    :ok = :gen_tcp.close(held)
    send(listener, :listen)

    assert {:ok, {{127, 0, 0, 1}, ^port}} = Callback.listening(listener)
    assert get(port, "/") =~ "404 Not Found"
  end

  test "it listens on loopback unless told where", %{port: port} do
    assert {:ok, {{127, 0, 0, 1}, ^port}} = Callback.listening()

    {:ok, held} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, other} = :inet.port(held)
    :ok = :gen_tcp.close(held)

    {:ok, listener} =
      GenServer.start_link(Callback, oauth: oauth(), ip: {0, 0, 0, 0}, port: other)

    assert {:ok, {{0, 0, 0, 0}, ^other}} = Callback.listening(listener)
  end
end
