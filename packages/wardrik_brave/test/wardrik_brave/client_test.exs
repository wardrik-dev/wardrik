defmodule WardrikBrave.ClientTest do
  use WardrikBrave.Case, async: true

  alias WardrikBrave.Client

  @body %{
    "grounding" => %{
      "generic" => [
        %{"url" => "https://a.test", "title" => "A", "snippets" => ["one", "two"]},
        %{"url" => "https://b.test", "title" => "B", "snippets" => []}
      ]
    },
    "sources" => %{"https://a.test" => %{"age" => ["2 days ago", "x", "y", "z"]}}
  }

  describe "search/2" do
    test "posts the query and summarizes what comes back" do
      stub_json(200, @body)

      assert {:ok, result} = Client.search(config(), %{"q" => "elixir otp"})

      assert result["count"] == 2
      assert [first, second] = result["results"]

      assert first == %{
               "url" => "https://a.test",
               "title" => "A",
               "snippets" => ["one", "two"],
               "age" => "2 days ago"
             }

      refute Map.has_key?(second, "age")

      assert_receive {:req, conn, body}
      assert conn.request_path == "/res/v1/llm/context"
      assert sent_body(body) == %{"q" => "elixir otp"}
    end

    test "sends the subscription token" do
      stub_json(200, @body)

      {:ok, _result} = Client.search(config(), %{"q" => "x"})

      assert_receive {:req, conn, _body}
      assert Plug.Conn.get_req_header(conn, "x-subscription-token") == ["test-brave-api-key"]
    end

    test "a build with no key reports that rather than calling out" do
      assert Client.search(config(api_key: nil), %{"q" => "x"}) ==
               {:error, :missing_brave_api_key}

      refute_receive {:req, _conn, _body}
    end

    test "a rate limit is named so a caller can tell it apart" do
      stub_status(429)

      assert Client.search(config(), %{"q" => "x"}) == {:error, :brave_rate_limited}
    end

    test "any other failure carries the status" do
      stub_status(503)

      assert {:error, message} = Client.search(config(), %{"q" => "x"})
      assert message =~ "503"
    end
  end

  describe "summarize/1" do
    test "no grounding is a search that found nothing" do
      assert Client.summarize(%{}) == %{"results" => [], "count" => 0}

      assert Client.summarize(%{"grounding" => %{"generic" => []}}) == %{
               "results" => [],
               "count" => 0
             }
    end

    test "a body that is not a map is also empty" do
      assert Client.summarize("nonsense") == %{"results" => [], "count" => 0}
    end

    test "an entry of an unexpected shape is kept rather than dropped" do
      assert %{"results" => [result]} =
               Client.summarize(%{"grounding" => %{"generic" => ["bare string"]}})

      assert result["snippets"] == []
      assert result["value"] =~ "bare string"
    end

    test "only the readable rendering of a date survives" do
      body = %{
        "grounding" => %{"generic" => [%{"url" => "https://a.test", "snippets" => []}]},
        "sources" => %{"https://a.test" => %{"age" => ["yesterday", "2026-09-09", "x", "y"]}}
      }

      assert %{"results" => [%{"age" => "yesterday"}]} = Client.summarize(body)
    end
  end

  test "headers/1 carries the key and asks for JSON" do
    assert Client.headers(config()) == %{
             "x-subscription-token" => "test-brave-api-key",
             "accept" => "application/json"
           }
  end
end
