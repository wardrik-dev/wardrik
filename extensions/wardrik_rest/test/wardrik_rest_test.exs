defmodule WardrikRestTest do
  use ExUnit.Case, async: true

  alias Wardrik.Context
  alias Wardrik.Credentials.Authorization
  alias WardrikRest.API
  alias WardrikRest.Discovery

  @document "test/fixtures/analyticsdata-v1beta.json"
            |> File.read!()
            |> JSON.decode!()

  @analytics {Discovery, document: @document}

  defp load(opts) do
    defaults = [name: "ga4", base_url: "https://analyticsdata.googleapis.com"]
    API.load(@analytics, Keyword.merge(defaults, opts))
  end

  defp tools(opts) do
    {:ok, api} = load(opts)
    listed = WardrikRest.tools(nil, apis: [api])
    Map.new(listed, &{&1.name, &1})
  end

  defp context(opts \\ []) do
    tokens =
      start_supervised!({Agent, fn -> Keyword.get(opts, :tokens, ["t0k3n"]) end}, id: make_ref())

    Context.new(
      agent_id: "acme/marketing",
      principal: %Wardrik.Principal{id: "org:acme"},
      credentials: {WardrikRest.Test.Credentials, tokens},
      keys: {WardrikRest.Test.Keys, Keyword.get(opts, :keys, %{})}
    )
  end

  defp stubbed(test), do: [req_options: [plug: {Req.Test, test}]]

  describe "load/2" do
    test "offers the operations named, with what they need" do
      tools =
        tools(
          auth: %{"oauth2" => {:credential, "google"}},
          only: ["properties_runReport", "properties_get*"],
          read_only: ["properties_runReport"]
        )

      names =
        tools
        |> Map.keys()
        |> Enum.sort()

      assert names == ["ga4__properties_getMetadata", "ga4__properties_runReport"]

      report = tools["ga4__properties_runReport"]
      assert report.annotations[:read_only] and report.annotations[:idempotent]
      assert report.annotations[:gated] == false
      assert report.annotations[:labels] == ["outside"]
      assert report.annotations[:open_world]
      assert report.schema["required"] == ["property"]
      assert report.description =~ "customized report"

      assert {:ok, _args} =
               ReqLLM.Schema.validate(
                 %{"property" => "properties/1", "metrics" => [%{"name" => "conversions"}]},
                 report.schema
               )
    end

    test "gates operations that may change something, unless trusted stops the label" do
      tools =
        tools(
          auth: %{"oauth2" => {:credential, "google"}},
          only: ["properties_audienceExports_create"],
          trusted: true
        )

      create = tools["ga4__properties_audienceExports_create"]

      assert create.annotations[:gated]
      refute create.annotations[:read_only] or create.annotations[:idempotent]
      assert create.annotations[:labels] == []
    end

    test "offers only what it can sign in to" do
      assert tools(only: ["*"]) == %{}
      assert map_size(tools(auth: %{"key" => {:key, "GOOGLE_KEY"}})) == 11
    end

    test "says what's wrong with the options" do
      oauth = %{"oauth2" => {:credential, "google"}}

      assert load(auth: %{"basic" => {:key, "K"}}) ==
               {:error, "auth names basic, which the description doesn't. It has key, oauth2."}

      assert load(auth: oauth, only: ["properties_nothing"]) ==
               {:error, "The description has no operation properties_nothing."}

      assert load(only: ["properties_runReport"]) ==
               {:error,
                "auth gives no way to sign in to properties_runReport. Each needs oauth2 or key."}

      long = [name: String.duplicate("a", 40), base_url: "https://a.test", auth: oauth]

      assert {:error, "These tool names would be over 64 characters" <> _rest} =
               API.load(@analytics, long ++ [only: ["properties_audienceExports_create"]])

      # A glob leaves out what's too long for it, and keeps what fits.
      assert {:ok, api} = API.load(@analytics, long)
      names = Enum.map(api.operations, & &1.name)
      assert "properties_runReport" in names
      refute "properties_audienceExports_create" in names

      assert load(auth: oauth, base_url: "http://analyticsdata.googleapis.com") ==
               {:error, "http://analyticsdata.googleapis.com isn't an https URL."}

      assert load(egress: fn _url -> {:error, "not here"} end) == {:error, "not here"}

      assert {:error, "It isn't a Discovery document."} =
               API.load({Discovery, document: %{}}, name: "x", base_url: "https://x.test")
    end

    test "fits a long schema into max_schema_bytes, naming deeper types for describe to give" do
      tools =
        tools(
          auth: %{"oauth2" => {:credential, "google"}},
          only: ["properties_runReport", "properties_getMetadata"],
          max_schema_bytes: 6_000
        )

      report = tools["ga4__properties_runReport"]
      assert byte_size(JSON.encode!(report.schema)) <= 6_000
      assert report.schema["required"] == ["property"]

      assert %{"type" => "object", "description" => "Dimension filters" <> named} =
               report.schema["properties"]["dimensionFilter"]

      assert named =~ "A FilterExpression; ga4__describe gives its fields."

      describe = tools["ga4__describe"]
      assert describe.annotations[:read_only] and not describe.annotations[:gated]
      assert describe.description =~ "as "

      assert {:ok, %{"properties" => %{"andGroup" => and_group, "filter" => filter}}} =
               describe.run.(%{"type" => "FilterExpression"}, context())

      assert and_group["description"] =~ "The FilterExpressions in and_group"
      assert and_group["description"] =~ "A FilterExpressionList; ga4__describe gives its fields."
      assert filter["type"] == "object"

      assert {:ok, %{"properties" => %{"expressions" => expressions}}} =
               describe.run.(%{"type" => "FilterExpressionList"}, context())

      assert expressions["items"]["description"] ==
               "A FilterExpression; ga4__describe gives its fields."

      assert {:error, "ga4 has no type Nothing. Its tools name " <> names} =
               describe.run.(%{"type" => "Nothing"}, context())

      assert names =~ "FilterExpression"
    end

    test "inlines a schema that fits whole, and its types that refer to themselves" do
      tools = tools(auth: %{"oauth2" => {:credential, "google"}}, only: ["properties_runReport"])
      refute Map.has_key?(tools, "ga4__describe")

      filter = tools["ga4__properties_runReport"].schema["properties"]["dimensionFilter"]

      assert filter["properties"]["andGroup"]["properties"]["expressions"]["items"] == %{
               "type" => "object",
               "description" => "A FilterExpression, as above."
             }

      refute Map.has_key?(filter["properties"]["filter"], "description")
    end

    test "names no scheme when the description has none" do
      notes = {Discovery, document: %{"kind" => "discovery#restDescription", "name" => "notes"}}

      assert API.load(notes,
               name: "notes",
               base_url: "https://notes.test",
               auth: %{"oauth2" => {:key, "K"}}
             ) ==
               {:error, "auth names oauth2, which the description doesn't. It has none."}
    end
  end

  describe "a call" do
    setup %{test: test} do
      tools =
        tools(
          [
            auth: %{"oauth2" => {:credential, "google"}},
            headers: %{"x-goog-user-project" => {:key, "PROJECT"}, "x-client" => "wardrik"},
            argument_headers: %{"login-customer-id" => "The manager account's ID."},
            only: [
              "properties_runReport",
              "properties_getMetadata",
              "properties_audienceExports_list"
            ]
          ] ++ stubbed(test)
        )

      %{tools: tools, test_pid: self()}
    end

    test "sends the token, headers, path, query and body", %{
      tools: tools,
      test: test,
      test_pid: pid
    } do
      Req.Test.stub(test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          pid,
          {:called, conn.method, conn.request_path, conn.query_string, conn.req_headers, body}
        )

        Req.Test.json(conn, %{"rows" => [%{"metricValues" => [%{"value" => "12"}]}]})
      end)

      assert tools["ga4__properties_runReport"].schema["properties"]["login-customer-id"] == %{
               "type" => "string",
               "description" => "The manager account's ID."
             }

      args = %{
        "property" => "properties/123",
        "login-customer-id" => 42,
        "metrics" => [%{"name" => "conversions"}],
        "dateRanges" => [%{"startDate" => "28daysAgo", "endDate" => "today"}]
      }

      context = context(keys: %{"PROJECT" => "mode-prod"})

      assert tools["ga4__properties_runReport"].run.(args, context) ==
               {:ok, %{"rows" => [%{"metricValues" => [%{"value" => "12"}]}]}}

      assert_received {:called, "POST", "/v1beta/properties/123:runReport", "", headers, body}
      assert {"authorization", "Bearer t0k3n"} in headers
      assert {"x-goog-user-project", "mode-prod"} in headers
      assert {"x-client", "wardrik"} in headers
      assert {"login-customer-id", "42"} in headers

      assert JSON.decode!(body) == %{
               "metrics" => [%{"name" => "conversions"}],
               "dateRanges" => [%{"startDate" => "28daysAgo", "endDate" => "today"}]
             }
    end

    test "sends a GET's query without a body, and an empty answer as an empty map", %{
      tools: tools,
      test: test,
      test_pid: pid
    } do
      Req.Test.stub(test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(pid, {:called, conn.method, conn.request_path, conn.query_string, body})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      args = %{parent: "properties/1", pageSize: 5, pageToken: "next page"}
      context = context(keys: %{"PROJECT" => "p"})

      assert tools["ga4__properties_audienceExports_list"].run.(args, context) == {:ok, %{}}
      assert_received {:called, "GET", "/v1beta/properties/1/audienceExports", query, ""}
      assert URI.decode_query(query) == %{"pageSize" => "5", "pageToken" => "next page"}
    end

    test "encodes a plain path parameter whole", %{test: test, test_pid: pid} do
      notes =
        {Discovery,
         document: %{
           "kind" => "discovery#restDescription",
           "name" => "notes",
           "parameters" => %{"key" => %{"type" => "string", "location" => "query"}},
           "auth" => %{"oauth2" => %{}},
           "resources" => %{
             "notes" => %{
               "methods" => %{
                 "get" => %{
                   "id" => "notes.notes.get",
                   "httpMethod" => "GET",
                   "path" => "notes/{id}",
                   "scopes" => ["notes"],
                   "parameters" => %{
                     "id" => %{"type" => "string", "location" => "path", "required" => true}
                   }
                 }
               }
             }
           }
         }}

      {:ok, api} =
        API.load(
          notes,
          [name: "notes", base_url: "https://notes.test/", auth: %{"key" => {:key, "NOTES_KEY"}}] ++
            stubbed(test)
        )

      Req.Test.stub(test, fn conn ->
        send(pid, {:called, conn.request_path, conn.query_string, conn.req_headers})
        Req.Test.json(conn, %{"id" => "a/b"})
      end)

      [tool] = WardrikRest.tools(nil, apis: [api])

      assert tool.run.(%{"id" => "a/b"}, context(keys: %{"NOTES_KEY" => "s3cret"})) ==
               {:ok, %{"id" => "a/b"}}

      assert_received {:called, "/notes/a%2Fb", "key=s3cret", headers}
      refute List.keymember?(headers, "authorization", 0)

      assert tool.run.(%{"id" => "x"}, context()) == {:error, "notes has no NOTES_KEY key yet."}
    end

    test "cuts an answer longer than max_result_bytes, and says how to get less", %{test: test} do
      tools =
        tools(
          auth: %{"oauth2" => {:credential, "google"}},
          only: ["properties_getMetadata"],
          max_result_bytes: 40,
          req_options: [plug: {Req.Test, test}]
        )

      metadata = tools["ga4__properties_getMetadata"]
      rows = %{"rows" => Enum.map(1..10, &%{"value" => &1})}

      Req.Test.stub(test, &Req.Test.json(&1, %{"ok" => true}))
      assert metadata.run.(%{"name" => "n"}, context()) == {:ok, %{"ok" => true}}

      Req.Test.stub(test, &Req.Test.json(&1, rows))
      {:ok, cut} = metadata.run.(%{"name" => "n"}, context())

      assert cut ==
               binary_part(JSON.encode!(rows), 0, 40) <>
                 "\n[Cut to 40 of #{byte_size(JSON.encode!(rows))} bytes. Ask for less, such as fewer rows or fields.]"

      Req.Test.stub(test, &Plug.Conn.send_resp(&1, 200, String.duplicate("é", 30)))
      {:ok, text} = metadata.run.(%{"name" => "n"}, context())
      assert String.valid?(text) and String.starts_with?(text, String.duplicate("é", 20) <> "\n")
    end

    test "tells credentials a refused token, then calls once more", %{tools: tools, test: test} do
      Req.Test.stub(test, fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer fresh"] -> Req.Test.json(conn, %{"dimensions" => []})
          _stale -> Plug.Conn.send_resp(conn, 401, "{}")
        end
      end)

      metadata = tools["ga4__properties_getMetadata"]
      context = context(tokens: ["stale", "fresh"], keys: %{"PROJECT" => "p"})

      assert metadata.run.(%{"name" => "properties/1/metadata"}, context) ==
               {:ok, %{"dimensions" => []}}

      assert_received {:refused, "google"}
    end

    test "waits for a sign-in when the token is refused again, or there's none", %{
      tools: tools,
      test: test
    } do
      Req.Test.stub(test, &Plug.Conn.send_resp(&1, 401, "{}"))
      metadata = tools["ga4__properties_getMetadata"]

      assert {:park, %Authorization{credential: "google", url: "https://accounts.test/sign-in"}} =
               metadata.run.(
                 %{"name" => "properties/1/metadata"},
                 context(tokens: ["stale"], keys: %{"PROJECT" => "p"})
               )

      assert {:park, %Authorization{}} =
               metadata.run.(%{}, context(tokens: [], keys: %{"PROJECT" => "p"}))
    end

    test "answers a refusal the second time with its status", %{tools: tools, test: test} do
      Req.Test.stub(
        test,
        &Req.Test.json(Plug.Conn.put_status(&1, 401), %{"message" => "Bad token"})
      )

      metadata = tools["ga4__properties_getMetadata"]
      context = context(tokens: ["one", "two"], keys: %{"PROJECT" => "p"})

      assert metadata.run.(%{"name" => "n"}, context) == {:error, "ga4 answered 401: Bad token"}
    end

    test "answers the API's message for other refusals", %{tools: tools, test: test} do
      context = context(keys: %{"PROJECT" => "p"})
      metadata = tools["ga4__properties_getMetadata"]

      Req.Test.stub(test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          ~s({"error": {"code": 403, "message": "No access to property 1."}})
        )
      end)

      assert metadata.run.(%{"name" => "n"}, context) ==
               {:error, "ga4 answered 403: No access to property 1."}

      Req.Test.stub(test, &Plug.Conn.send_resp(&1, 400, "bad request"))
      assert metadata.run.(%{"name" => "n"}, context) == {:error, "ga4 answered 400: bad request"}

      Req.Test.stub(test, &Req.Test.json(Plug.Conn.put_status(&1, 404), ["nothing"]))

      assert metadata.run.(%{"name" => "n"}, context) ==
               {:error, ~s(ga4 answered 404: ["nothing"])}
    end

    test "raises so the runner retries a limit, a server error or no answer", %{
      tools: tools,
      test: test
    } do
      context = context(keys: %{"PROJECT" => "p"})
      metadata = tools["ga4__properties_getMetadata"]

      Req.Test.stub(test, &Plug.Conn.send_resp(&1, 429, ""))

      assert_raise WardrikRest.Unavailable, "ga4 answered 429.", fn ->
        metadata.run.(%{}, context)
      end

      Req.Test.stub(test, &Plug.Conn.send_resp(&1, 503, ""))

      assert_raise WardrikRest.Unavailable, "ga4 answered 503.", fn ->
        metadata.run.(%{}, context)
      end

      Req.Test.stub(test, &Req.Test.transport_error(&1, :timeout))

      assert_raise WardrikRest.Unavailable, ~r/ga4 didn't answer/, fn ->
        metadata.run.(%{}, context)
      end
    end

    test "says why it can't sign in or read a key", %{tools: tools} do
      metadata = tools["ga4__properties_getMetadata"]
      broken = %{context() | keys: {__MODULE__.BrokenKeys, []}, credentials: nil}

      assert metadata.run.(%{}, broken) ==
               {:error, "ga4 can't sign in with google: No credentials to give google."}

      no_key = %{context() | keys: {__MODULE__.BrokenKeys, []}}
      assert metadata.run.(%{}, no_key) == {:error, "ga4 can't read its PROJECT key: :locked"}
    end
  end

  defmodule BrokenKeys do
    @behaviour Wardrik.Keys
    @impl true
    def fetch(_request, _opts), do: {:error, :locked}
  end
end
