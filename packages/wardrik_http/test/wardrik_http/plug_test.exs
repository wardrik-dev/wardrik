defmodule WardrikHTTP.PlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Wardrik.Host

  # Knows a request by its x-user header, as someone in the org test.
  defmodule Agents do
    @moduledoc false
    use Wardrik, otp_app: :wardrik_http

    @impl Wardrik
    def principal(%{org: org, id: id}), do: %{org: org, id: id, name: "user #{id}"}

    @impl Wardrik
    def authenticate(conn) do
      case Plug.Conn.get_req_header(conn, "x-user") do
        [id] -> {:ok, %{org: "test", id: id}}
        [] -> :error
      end
    end
  end

  defmodule Unauthenticated do
    @moduledoc false
    use Wardrik, otp_app: :wardrik_http

    @impl Wardrik
    def principal(%{org: org, id: id}), do: %{org: org, id: id}
  end

  # An app's endpoint, serving the API under /agents ahead of its parsers.
  defmodule Endpoint do
    @moduledoc false
    use Plug.Builder

    plug WardrikHTTP.Plug, at: "/agents", agents: Agents
    plug Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"]
    plug :own

    def own(conn, _opts), do: send_resp(conn, 404, "the app's own 404")
  end

  # An endpoint that parses bodies before it mounts the API.
  defmodule Parsed do
    @moduledoc false
    use Plug.Builder

    plug Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"]
    plug WardrikHTTP.Plug, at: "/agents", agents: Agents
  end

  defmodule Page do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, test: test) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:routed, conn.script_name, conn.path_info, body})
      Plug.Conn.send_resp(conn, 200, "page")
    end
  end

  # The instance's host as it builds it from its config, on the suite's
  # runtime, which already runs Wardrik on this node.
  defp started(module, config) do
    Application.put_env(:wardrik_http, module, [store: :memory] ++ config)
    host = Wardrik.Instance.build(module, module.config())
    host = %{host | llm: Wardrik.Test.llm(), runtimes: Wardrik.Test.runtimes()}
    Wardrik.Instance.put(module, host)

    on_exit(fn ->
      Application.delete_env(:wardrik_http, module)
      :persistent_term.erase({Wardrik.Instance, module})
    end)

    host
  end

  defp request(method, path, user \\ nil, body \\ nil) do
    conn = conn(method, path, body)
    conn = if user, do: put_req_header(conn, "x-user", user), else: conn
    conn = put_req_header(conn, "content-type", "application/json")
    Endpoint.call(conn, Endpoint.init([]))
  end

  test "serves an instance's agents to the user its authenticate/1 knows" do
    started(Agents, plugins: [WardrikHTTP])
    id = "u#{System.unique_integer([:positive])}"
    user = %{org: "test", id: id}

    assert {:ok, _snapshot} =
             Agents.define(user, "support",
               model: "anthropic:claude-sonnet-5",
               instructions: "Hi."
             )

    conn = request(:get, "/agents/v1/agents", id)
    assert conn.status == 200
    assert "test/@#{id}/support" in Enum.map(JSON.decode!(conn.resp_body)["agents"], & &1["id"])

    other = request(:get, "/agents/v1/agents", "someone-else")
    refute "test/@#{id}/support" in Enum.map(JSON.decode!(other.resp_body)["agents"], & &1["id"])

    refused = request(:get, "/agents/v1/agents")
    assert refused.status == 401
    assert get_resp_header(refused, "www-authenticate") == ["Bearer"]
  end

  test "serves the host's routes under the API's path, or as the whole of the request's" do
    host = started(Agents, plugins: [WardrikHTTP])

    Wardrik.Instance.put(
      Agents,
      Host.register(host, :routes, [
        {["v1", "channels"], {Page, test: self()}},
        {["agents", "oauth"], {Page, test: self()}}
      ])
    )

    signed = ~s({"type":"event_callback","event":{"text":"hi"}})
    assert request(:post, "/agents/v1/channels/chat/events", nil, signed).resp_body == "page"
    assert_received {:routed, ["agents"], ["v1", "channels", "chat", "events"], ^signed}

    assert request(:get, "/agents/oauth/callback/github").resp_body == "page"
    assert_received {:routed, ["agents"], ["oauth", "callback", "github"], ""}

    assert request(:get, "/oauth/callback/github").resp_body == "the app's own 404"
  end

  test "passes on every request it doesn't serve, its body unread" do
    started(Agents, plugins: [WardrikHTTP])

    conn = request(:post, "/api/things", nil, ~s({"a":1}))
    assert conn.resp_body == "the app's own 404"
    assert conn.body_params == %{"a" => 1}
  end

  test "says where to mount it when a body was parsed before it" do
    started(Agents, plugins: [WardrikHTTP])

    conn =
      put_req_header(conn(:post, "/agents/v1/agents", "{}"), "content-type", "application/json")

    assert_raise ArgumentError, ~r/plug WardrikHTTP.Plug, at: "\/agents", agents: /, fn ->
      Parsed.call(conn, Parsed.init([]))
    end
  end

  test "serves a path, never the whole endpoint" do
    assert_raise ArgumentError, ~r/the path it serves/, fn ->
      WardrikHTTP.Plug.init(at: "/", agents: Agents)
    end

    assert_raise KeyError, ~r/:at/, fn -> WardrikHTTP.Plug.init(agents: Agents) end
  end

  test "won't serve an instance that says nothing of who a request comes from" do
    assert_raise ArgumentError, ~r/def authenticate\(conn\)/, fn ->
      WardrikHTTP.Plug.init(at: "/agents", agents: Unauthenticated)
    end
  end

  test "says what to add to an instance that runs nothing the API needs" do
    started(Agents, [])

    assert_raise ArgumentError, ~r/add WardrikHTTP to its plugins/, fn ->
      WardrikHTTP.Plug.call(
        conn(:get, "/agents/v1/agents"),
        WardrikHTTP.Plug.init(at: "/agents", agents: Agents)
      )
    end
  end

  test "a listener of the instance's own knows each request as the plug does" do
    host = started(Agents, plugins: [{WardrikHTTP, port: 0}])

    assert {WardrikHTTP.Listener, opts} =
             List.keyfind(Host.children(host), WardrikHTTP.Listener, 0)

    assert opts[:authenticator] == %WardrikHTTP.Instance{agents: Agents}

    assert_raise ArgumentError, ~r/def authenticate\(conn\)/, fn ->
      started(Unauthenticated, plugins: [{WardrikHTTP, port: 0}])
    end
  end
end
