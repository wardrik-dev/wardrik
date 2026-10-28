defmodule Wardrik.HTTPTest do
  use ExUnit.Case, async: false
  use Mimic

  import Plug.Conn
  import Plug.Test
  import Wardrik.Test.HTTP

  setup :set_mimic_global
  setup :start_wardrik

  @notes "/v1/agents/acme/@maria/notes"

  describe "operations" do
    test "runs an operation at its route, as whoever the token acts for", context do
      conn = request(context, "PUT", @notes, %{"model" => "anthropic:claude-haiku-4-5"})

      assert conn.status == 200
      assert %{"agent" => %{"id" => "acme/@maria/notes"}} = body(conn)
      assert [_request_id] = get_resp_header(conn, "request-id")

      conn = request(context, "GET", "/v1/agents?resources=acme/@maria/*&resources=acme/agent/*")
      assert %{"agents" => [%{"id" => "acme/@maria/notes"}]} = body(conn)

      conn = request(context, "GET", "/v1/agents/acme/%40maria/notes/definition")
      assert %{"definition" => %{"model" => "anthropic:claude-haiku-4-5"}} = body(conn)
    end

    test "answers nothing where the operation answers nothing", context do
      request(context, "PUT", @notes, %{"model" => "anthropic:claude-haiku-4-5"})

      conn = request(context, "DELETE", @notes)
      assert {conn.status, conn.resp_body} == {204, ""}
    end

    test "reads integers from the query", context do
      conn = request(context, "GET", "/v1/deployment/audit?limit=1")
      assert %{"events" => [%{"type" => "wardrik.token.created"}]} = body(conn)

      conn = request(context, "GET", "/v1/deployment/audit?limit=many")
      assert {conn.status, body(conn)["error"]["type"]} == {400, "invalid_request"}
    end

    test "keeps the caller's own request id", context do
      conn =
        request(context, "GET", "/v1/tokens", nil, [{"request-id", "req_0123456789abcdefghij"}])

      assert get_resp_header(conn, "request-id") == ["req_0123456789abcdefghij"]
    end
  end

  describe "refusals" do
    test "asks for a token where none is sent, or one isn't known", context do
      conn =
        Wardrik.HTTP.call(conn("GET", "/v1/agents"), Wardrik.HTTP.init(wardrik: context.wardrik))

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert %{"error" => %{"type" => "unauthorized"}} = body(conn)

      assert request(%{context | secret: "wrk_nope"}, "GET", "/v1/agents").status == 401
    end

    test "answers the protocol's error where an operation fails", context do
      conn = request(context, "GET", "/v1/agents/acme/missing")
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

    test "refuses a path segment that holds a slash", context do
      assert request(context, "GET", "/v1/agents/acme%2Fnotes/x").status == 400
    end

    test "needs a Wardrik to serve" do
      assert_raise ArgumentError, ~r/wardrik: MyApp.Wardrik/, fn -> Wardrik.HTTP.init([]) end
    end
  end

  describe "webhooks" do
    setup context do
      :ok = Wardrik.put_secret(context.wardrik, "acme", "HOOK", "s3cret")

      request(context, "PUT", "/v1/agents/acme/hooks", %{
        "model" => "anthropic:claude-haiku-4-5",
        "triggers" => [
          %{"name" => "issues", "webhook" => %{"secret" => "${HOOK}"}, "prompt" => "Triage it."}
        ]
      })

      :ok
    end

    test "delivers a request that proves itself with the trigger's secret, with no token",
         context do
      answers([answer("Triaged.")])

      :ok =
        WardrikEvents.subscribe(Wardrik.events(Wardrik.Instance.fetch!(context.wardrik)), ["*"])

      conn = hook(context, "/v1/hooks/acme/hooks/issues", [{"authorization", "Bearer s3cret"}])
      assert {conn.status, conn.resp_body} == {202, ""}
      assert_receive {WardrikEvents, _log, %{"type" => "wardrik.run.completed"}}

      assert hook(context, "/v1/hooks/acme/hooks/issues/s3cret", []).status == 202
      assert hook(context, "/v1/hooks/acme/hooks/issues/nope", []).status == 404
    end

    test "checks the body as it came where the app parsed it first", context do
      parsers =
        Plug.Parsers.init(
          parsers: [:json],
          json_decoder: JSON,
          body_reader: {WardrikHTTP.BodyReader, :read_body, []}
        )

      conn =
        "POST"
        |> conn("/v1/hooks/acme/hooks/issues/nope", ~s({"action":"opened"}))
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(parsers)
        |> Wardrik.HTTP.call(Wardrik.HTTP.init(wardrik: context.wardrik))

      assert conn.status == 404
    end

    test "says how to keep the body where the app parsed it without keeping it", context do
      parsers = Plug.Parsers.init(parsers: [:json], json_decoder: JSON)

      conn =
        "POST"
        |> conn("/v1/hooks/acme/hooks/issues", ~s({"action":"opened"}))
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(parsers)
        |> Wardrik.HTTP.call(Wardrik.HTTP.init(wardrik: context.wardrik))

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
        |> Wardrik.HTTP.call(Wardrik.HTTP.init(wardrik: context.wardrik))

      assert conn.status == 200
    end
  end

  describe "channels" do
    @tag channels: [slack: {Wardrik.Test.HTTP.Channel, []}]
    test "hands a chat app's request to its channel as it came, and sends back its answer",
         context do
      conn =
        "POST"
        |> conn("/v1/channels/slack/events", ~s({"type":"url_verification"}))
        |> put_req_header("x-slack-signature", "v0=abc")
        |> Wardrik.HTTP.call(Wardrik.HTTP.init(wardrik: context.wardrik))

      assert {conn.status, conn.resp_body} == {200, ~s(events {"type":"url_verification"} v0=abc)}
      assert get_resp_header(conn, "content-type") == ["text/plain"]

      conn =
        Wardrik.HTTP.call(
          conn("POST", "/v1/channels/teams/events", "{}"),
          Wardrik.HTTP.init(wardrik: context.wardrik)
        )

      assert conn.status == 404
    end
  end

  describe "documents and pages" do
    test "answers the OpenAPI document", context do
      conn =
        Wardrik.HTTP.call(
          conn("GET", "/v1/openapi.json"),
          Wardrik.HTTP.init(wardrik: context.wardrik)
        )

      assert %{"openapi" => "3.1.0"} = body(conn)
    end

    test "has no sign-in pages where the Wardrik signs no one in", context do
      assert request(context, "GET", "/oauth/device/nope").status == 404
    end

    @tag oauth: [page: "http://localhost/oauth", providers: []]
    test "serves the sign-in pages where the Wardrik signs people in", context do
      conn = request(context, "GET", "/oauth/device/nope")
      assert conn.status == 404
      assert conn.resp_body =~ "Sign-in not found"
    end
  end

  defp hook(context, path, headers) do
    "POST"
    |> conn(path, ~s({"action":"opened"}))
    |> merge_req_headers(headers)
    |> Wardrik.HTTP.call(Wardrik.HTTP.init(wardrik: context.wardrik))
  end
end
