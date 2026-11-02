defmodule WardrikHTTPTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test
  import WardrikHTTP.Test

  @notes "/v1/agents/acme%2F%40maria%2Fnotes"

  defmodule Pages do
    @moduledoc "The sign-in pages a test's server has."
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts),
      do: send_resp(conn, 200, "Sign in at /#{Enum.join(conn.path_info, "/")}")
  end

  def pages(:none), do: nil
  def pages(:some), do: {Pages, []}

  setup context do
    name = :"server #{context.test}"
    :ok = start(name, ["wrk_good"])
    %{name: name, secret: "wrk_good"}
  end

  describe "operations" do
    test "runs an operation at its route, with its path, query and body", context do
      conn = request(context, "PUT", @notes, %{"model" => "anthropic:claude-haiku-4-5"})

      assert conn.status == 200
      assert %{"agent" => %{"id" => _id}} = body(conn)
      assert [_request_id] = get_resp_header(conn, "request-id")

      assert_received {:ran, "agent.define",
                       %{"agent" => "acme/@maria/notes", "model" => "anthropic:claude-haiku-4-5"}}

      request(context, "GET", "/v1/agents?agents=acme%2F%40maria%2Fnotes&agents=agt_1")
      assert_received {:ran, "agents.list", %{"agents" => ["acme/@maria/notes", "agt_1"]}}
    end

    test "answers nothing where the operation answers nothing", context do
      conn = request(context, "DELETE", @notes)
      assert {conn.status, conn.resp_body} == {204, ""}
    end

    test "reads integers from the query, and hands on what isn't one for its server to refuse",
         context do
      request(context, "GET", "/v1/deployment/audit?limit=1")
      assert_received {:ran, "audit.list", %{"limit" => 1}}

      request(context, "GET", "/v1/deployment/audit?limit=many")
      assert_received {:ran, "audit.list", %{"limit" => "many"}}
    end

    test "keeps the caller's own request id", context do
      conn =
        request(context, "GET", "/v1/agents", nil, [{"request-id", "req_0123456789abcdefghij"}])

      assert get_resp_header(conn, "request-id") == ["req_0123456789abcdefghij"]
    end
  end

  describe "refusals" do
    test "asks for credentials where none are sent, or the authenticator refuses them", context do
      conn = WardrikHTTP.call(conn("GET", "/v1/agents"), settings(context))

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert %{"error" => %{"type" => "unauthorized"}} = body(conn)

      assert request(%{context | secret: "wrk_nope"}, "GET", "/v1/agents").status == 401
    end

    test "answers the protocol's error where an operation fails", context do
      conn = request(context, "GET", "/v1/agents/missing")
      assert {conn.status, body(conn)["error"]["type"]} == {404, "not_found"}
    end

    test "finds no route for a path no operation has", context do
      conn = request(context, "GET", "/v1/nothing")
      assert {conn.status, body(conn)["error"]["type"]} == {404, "not_found"}
    end

    test "refuses a body that isn't a JSON object", context do
      assert request(context, "PUT", @notes, "[1]").status == 400
      assert request(context, "PUT", @notes, "{").status == 400
    end

    test "takes an agent and a conversation each as one segment, slashes and all", context do
      conn = request(context, "GET", "/v1/agents/acme%2Fnotes/conversations/C1%2F2/timeline")
      assert conn.status == 200

      assert_received {:ran, "agent.timeline",
                       %{"agent" => "acme/notes", "conversation" => "C1/2"}}

      assert request(context, "GET", "/v1/agents/acme/notes/timeline").status == 404
    end

    test "won't start without a server, or without an authenticator" do
      assert_raise NimbleOptions.ValidationError, ~r/required :server option not found/, fn ->
        WardrikHTTP.init(authenticator: {WardrikHTTP.Test.Authenticator, []})
      end

      assert_raise NimbleOptions.ValidationError,
                   ~r/required :authenticator option not found/,
                   fn -> WardrikHTTP.init(server: {WardrikTesting.Server, :anything}) end

      assert_raise NimbleOptions.ValidationError,
                   ~r/required :authenticator option not found/,
                   fn ->
                     WardrikHTTP.child_spec(server: {WardrikTesting.Server, :anything}, port: 0)
                   end
    end
  end

  describe "webhooks" do
    test "hands a request to its trigger with no token, as whoever it is", context do
      conn = hook(context, "/v1/hooks/agt_hooks/issues", [{"authorization", "Bearer s3cret"}])
      assert {conn.status, conn.resp_body} == {202, ""}

      assert_received {:ran, "hook.deliver",
                       %{"agent" => "agt_hooks", "trigger" => "issues", "body" => body}}

      assert body == ~s({"action":"opened"})

      assert hook(context, "/v1/hooks/agt_hooks/issues/s3cret", []).status == 202
      assert_received {:ran, "hook.deliver_with_secret", %{"secret" => "s3cret"}}
    end

    test "hands on the body as it came where the app parsed it first", context do
      parsers =
        Plug.Parsers.init(
          parsers: [:json],
          json_decoder: JSON,
          body_reader: {WardrikHTTP.BodyReader, :read_body, []}
        )

      "POST"
      |> conn("/v1/hooks/agt_hooks/issues", ~s({"action": "opened"}))
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(parsers)
      |> WardrikHTTP.call(settings(context))

      assert_received {:ran, "hook.deliver", %{"body" => ~s({"action": "opened"})}}
    end

    test "says how to keep the body where the app parsed it without keeping it", context do
      parsers = Plug.Parsers.init(parsers: [:json], json_decoder: JSON)

      conn =
        "POST"
        |> conn("/v1/hooks/agt_hooks/issues", ~s({"action":"opened"}))
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(parsers)
        |> WardrikHTTP.call(settings(context))

      assert conn.status == 500
      assert body(conn)["error"]["message"] =~ "WardrikHTTP.BodyReader"
    end

    test "reads a parsed body for every other operation", context do
      parsers = Plug.Parsers.init(parsers: [:json], json_decoder: JSON)

      conn =
        "PUT"
        |> conn(@notes, ~s({"model":"anthropic:claude-haiku-4-5"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> context.secret)
        |> Plug.Parsers.call(parsers)
        |> WardrikHTTP.call(settings(context))

      assert conn.status == 200
    end
  end

  test "hands a chat app's request to its channel as it came, and sends back its answer",
       context do
    conn =
      "POST"
      |> conn("/v1/channels/slack/events", ~s({"type":"url_verification"}))
      |> put_req_header("x-slack-signature", "v0=abc")
      |> WardrikHTTP.call(settings(context))

    assert_received {:ran, "channel.deliver",
                     %{"channel" => "slack", "path" => "events", "headers" => headers}}

    assert headers["x-slack-signature"] == "v0=abc"
    assert conn.status in 200..599
  end

  describe "documents and pages" do
    test "answers the OpenAPI document", context do
      conn = WardrikHTTP.call(conn("GET", "/v1/openapi.json"), settings(context))
      assert %{"openapi" => "3.1.0"} = body(conn)
    end

    test "has no sign-in pages where its server signs no one in", context do
      settings = settings(context, sign_in: {__MODULE__, :pages, [:none]})
      assert WardrikHTTP.call(conn("GET", "/oauth/device/x"), settings).status == 404
    end

    test "serves the sign-in pages its server has", context do
      settings = settings(context, sign_in: {__MODULE__, :pages, [:some]})
      conn = WardrikHTTP.call(conn("GET", "/oauth/device/x"), settings)
      assert {conn.status, conn.resp_body} == {200, "Sign in at /device/x"}
    end
  end

  defp hook(context, path, headers) do
    "POST"
    |> conn(path, ~s({"action":"opened"}))
    |> merge_req_headers(headers)
    |> WardrikHTTP.call(settings(context))
  end
end
