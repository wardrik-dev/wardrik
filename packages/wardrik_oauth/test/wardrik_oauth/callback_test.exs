defmodule WardrikOAuth.CallbackTest do
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias Wardrik.Test.Calls
  alias WardrikOAuth.Callback
  alias WardrikOAuth.Callback.Page
  alias WardrikOAuth.Pending

  setup do
    start_supervised!(WardrikOAuth.Supervisor)
    configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])
  end

  # Starts a flow for `owner` against a stub server answering with `server`.
  defp flow(%{owner: owner}, server \\ []) do
    stub_server([cimd: true] ++ server)

    id = AgentID.new!("a", org: "acme", user: owner)
    run = Config.new() |> Run.root(id, host: host())

    {:error, {:authorization_required, %{url: url}, _owner}} =
      Credential.resolve(Calls.tool("tool", %{}, run), "github")

    %{run: run, url: url, state: state_of(url)}
  end

  # The pages as a host serves them, handed the request with its path whole.
  defp get(target), do: :get |> Plug.Test.conn(target) |> Page.call(Page.init(oauth: oauth()))

  test "a browser coming back with a code finishes the flow, at the provider's own path",
       context do
    %{url: url, state: state, run: run} = flow(context)
    assert params_of(url)["redirect_uri"] == redirect_uri()

    conn = get("/oauth/callback/github?code=the-code&state=#{state}")

    assert conn.status == 200
    assert conn.resp_body =~ "github is connected"

    assert {:ok, credential} =
             Credential.resolve(Calls.tool("tool", %{}, run), "github")

    assert Credential.reveal(credential) == "at_first"
  end

  test "a code that comes back to another provider's path finishes nothing", context do
    %{state: state} = flow(context)

    assert get("/oauth/callback/linear?code=the-code&state=#{state}").status == 404
    assert {:ok, _flight} = Pending.under_way("github", person("acme", context.owner))
    assert get("/oauth/callback/github?code=the-code&state=#{state}").status == 200
  end

  test "a callback naming another issuer finishes nothing", context do
    %{state: state} = flow(context)
    callback = "/oauth/callback/github?code=c&state=#{state}&iss="

    assert get(callback <> "https%3A%2F%2Fevil.example.com").status == 400
    assert get(callback <> "https%3A%2F%2Fauth.example.com").status == 200
  end

  test "a callback without iss, from an issuer that says it sends one, finishes nothing",
       context do
    %{state: state} = flow(context, iss: true)
    callback = "/oauth/callback/github?code=c&state=#{state}"

    assert get(callback).status == 400
    assert get(callback <> "&iss=https%3A%2F%2Fauth.example.com").status == 200
  end

  test "a callback the user refused says so, escaped, and stores nothing", context do
    flow(context)

    conn = get("/oauth/callback/github?error=access_denied&error_description=%3Cscript%3E")

    assert conn.status == 400
    assert conn.resp_body =~ "access_denied: &lt;script&gt;"
    refute conn.resp_body =~ "<script>"
    refute WardrikOAuth.connected?(vault(), "github", person("acme", context.owner))
  end

  test "a callback with no code is refused", context do
    flow(context)
    assert get("/oauth/callback/github").status == 400
  end

  test "is served under the redirect URL's own path, for a front that passes requests on as they came",
       context do
    %{state: state} = flow(context)

    assert [{["oauth", "callback"], {Page, _}}, {["oauth", "check"], {Page, _}}] =
             Callback.pages(oauth())

    assert get("/callback/github?code=the-code&state=#{state}").status == 404
    assert get("/oauth/callback/github?code=the-code&state=#{state}").status == 200
  end

  # The request as an app's router hands it on, having forwarded `mount`.
  defp forwarded(target, mount) do
    conn = Plug.Test.conn(:get, target)
    %{conn | script_name: mount, path_info: Enum.drop(conn.path_info, length(mount))}
  end

  test "is served under the redirect URL's path from wherever an app forwards it", context do
    %{state: state} = flow(context)
    conn = forwarded("/oauth/callback/github?code=the-code&state=#{state}", ["oauth"])

    assert Page.call(conn, Page.init(oauth: oauth())).status == 200
  end

  describe "WardrikOAuth.Plug" do
    defmodule Agents do
      @moduledoc false
      use Wardrik, otp_app: :wardrik_oauth

      @impl Wardrik
      def principal(%{org: org, id: id}), do: %{org: org, id: id}
    end

    setup do
      on_exit(fn -> :persistent_term.erase({Wardrik.Instance, Agents}) end)
    end

    test "serves an instance's pages where the app forwards their path", context do
      %{state: state} = flow(context)
      Wardrik.Instance.put(Agents, WardrikOAuth.attach(host(), oauth: oauth()))
      conn = forwarded("/oauth/callback/github?code=the-code&state=#{state}", ["oauth"])

      assert WardrikOAuth.Plug.call(conn, WardrikOAuth.Plug.init(agents: Agents)).status == 200
    end

    test "says what to add to an instance that signs in to nothing" do
      Wardrik.Instance.put(Agents, host())
      conn = forwarded("/oauth/callback/github", ["oauth"])

      assert_raise ArgumentError, ~r/add WardrikOAuth to its plugins/, fn ->
        WardrikOAuth.Plug.call(conn, WardrikOAuth.Plug.init(agents: Agents))
      end
    end
  end

  test "every page is kept from caches, referrers and frames, and loads nothing", context do
    flow(context)

    for conn <- [get("/oauth/callback/github"), get("/oauth/elsewhere")] do
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert Plug.Conn.get_resp_header(conn, "referrer-policy") == ["no-referrer"]

      assert ["default-src 'none'" <> _] =
               Plug.Conn.get_resp_header(conn, "content-security-policy")

      assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["DENY"]
    end
  end

  test "check answers with the nonce it was sent, so the URL can be shown to reach it" do
    assert get("/oauth/check?nonce=abc-1").resp_body == "wardrik abc-1"
    assert get("/oauth/check?nonce=%3Cscript%3E").status == 400
    assert get("/oauth/check").status == 400

    assert Callback.check(Callback.url(oauth()), plug: {Page, oauth: oauth()}) == :ok

    {:ok, other} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed} = :inet.port(other)
    :ok = :gen_tcp.close(other)
    assert {:error, "http://127.0.0.1:" <> _} = Callback.check("http://127.0.0.1:#{closed}")
  end

  test "a URL on loopback is this machine's, and opens the browser here" do
    refute Callback.loopback?(oauth())

    configure(redirect: [url: "http://localhost:4747/oauth/"])
    assert Callback.loopback?(oauth())

    assert Callback.redirect_uri(oauth(), "github") ==
             "http://localhost:4747/oauth/callback/github"
  end

  test "a path that is not a callback is not served" do
    assert get("/oauth").status == 404
    assert get("/oauth/callback").status == 404
  end
end
