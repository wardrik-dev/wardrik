defmodule WardrikBrave.WebSearchTest do
  use WardrikBrave.Case, async: true

  alias WardrikBrave.WebSearch

  import Wardrik.Credential, only: [secret: 1]

  @body %{"grounding" => %{"generic" => [%{"url" => "https://a.test", "snippets" => ["hi"]}]}}

  describe "tool/0" do
    test "declares a web_search tool the model can call" do
      tool = WebSearch.tool()

      assert %ReqLLM.Tool{name: "web_search"} = tool
      assert tool.description =~ "Search the web"
    end

    test "answers with pages from outside, labelled so" do
      assert Wardrik.Tool.annotations(WebSearch, "web_search").labels == ["outside"]
    end

    test "needs the key, as a credential the call resolves" do
      assert Wardrik.Tool.annotations(WebSearch, "web_search").credentials == ["BRAVE_API_KEY"]
    end

    test "requires only a query" do
      assert {:ok, _input} = ReqLLM.Tool.validate_input(WebSearch.tool(), %{query: "elixir"})
      assert {:error, _reason} = ReqLLM.Tool.validate_input(WebSearch.tool(), %{})
    end
  end

  describe "body/1" do
    test "applies the defaults, which live only here" do
      assert WebSearch.body(%{query: "elixir"}) == %{
               "q" => "elixir",
               "count" => 10,
               "maximum_number_of_tokens" => 4096
             }
    end

    test "passes through what the caller set" do
      params = %{query: "elixir", count: 25, max_tokens: 16_384, freshness: "pw"}

      assert WebSearch.body(params) == %{
               "q" => "elixir",
               "count" => 25,
               "maximum_number_of_tokens" => 16_384,
               "freshness" => "pw"
             }
    end

    test "drops what was left unset rather than sending nulls" do
      refute Map.has_key?(WebSearch.body(%{query: "elixir", freshness: nil}), "freshness")
    end
  end

  describe "run/2" do
    test "a search reports its results under ok" do
      stub_json(200, @body)

      assert {:ok, %{"ok" => true, "result" => result}} =
               WebSearch.run(%{query: "elixir"}, config())

      assert result["count"] == 1
    end

    test "a failed search is a result the model can read, not a failed tool" do
      stub_status(429)

      assert {:ok, %{"ok" => false, "error" => error}} =
               WebSearch.run(%{query: "elixir"}, config())

      assert error["code"] == "brave_rate_limited"
    end

    test "a call searches with the key its credential resolved, and an empty one is none" do
      run = Wardrik.Test.run(tools: [WebSearch])
      context = Wardrik.Test.context(run, credentials: %{"BRAVE_API_KEY" => secret("")})

      assert {:ok, %{"ok" => false, "error" => error}} = WebSearch.run(%{query: "x"}, context)
      assert error["code"] == "missing_brave_api_key"
      refute_received {:req, _conn, _body}
    end

    test "a call with no key resolved reports the missing key" do
      context = Wardrik.Test.context(Wardrik.Test.run(tools: [WebSearch]))

      assert {:ok, %{"ok" => false, "error" => error}} = WebSearch.run(%{query: "x"}, context)
      assert error["code"] == "missing_brave_api_key"
    end

    test "a run that resolves no credentials is told why, and nothing runs" do
      run = Wardrik.Test.run(tools: [WebSearch])

      assert %Wardrik.Call{state: :done, result: {:ok, %{"ok" => false, "error" => error}}} =
               Wardrik.Test.call(run, "web_search", %{"query" => "x"})

      assert error["message"] =~ "BRAVE_API_KEY"
      refute_received {:req, _conn, _body}
    end
  end

  describe "the schema guides the model" do
    defp properties do
      WardrikBrave.WebSearch.tool()
      |> ReqLLM.Tool.to_json_schema()
      |> get_in(["function", "parameters", "properties"])
    end

    defp validate(args), do: ReqLLM.Tool.validate_input(WardrikBrave.WebSearch.tool(), args)

    test "freshness reaches the model as an enum, not prose" do
      assert properties()["freshness"]["enum"] == ["pd", "pw", "pm", "py"]
    end

    test "the integer bounds reach it as bounds" do
      assert %{"minimum" => 1, "maximum" => 50} = properties()["count"]
      assert %{"minimum" => 1_024, "maximum" => 32_768} = properties()["max_tokens"]
    end

    test "every parameter carries a description" do
      for {_name, property} <- properties(), do: assert(is_binary(property["description"]))
    end

    test "a freshness code outside the enum is refused" do
      assert {:error, error} = validate(%{query: "x", freshness: "p3m"})
      assert error.reason =~ ~s(expected one of ["pd", "pw", "pm", "py"])
    end

    test "out-of-range numbers are refused" do
      assert {:error, _} = validate(%{query: "x", count: 0})
      assert {:error, _} = validate(%{query: "x", count: 51})
      assert {:error, _} = validate(%{query: "x", max_tokens: 1_023})
      assert {:error, _} = validate(%{query: "x", max_tokens: 32_769})
    end

    test "a malformed window is refused with the format spelled out" do
      assert {:error, error} = validate(%{query: "x", published_between: "last month"})
      assert error.reason =~ "YYYY-MM-DDtoYYYY-MM-DD"
    end

    test "a well-formed window is accepted" do
      assert {:ok, _} = validate(%{query: "x", published_between: "2025-01-01to2025-06-30"})
    end

    test "the valid codes and a sane count pass" do
      for code <- ~w(pd pw pm py) do
        assert {:ok, _} = validate(%{query: "x", freshness: code})
      end

      assert {:ok, _} = validate(%{query: "x", count: 25, max_tokens: 8_192})
    end
  end

  describe "body/1 windows" do
    test "either way of asking for a window maps onto the one field Brave takes" do
      assert %{"freshness" => "pw"} = WardrikBrave.WebSearch.body(%{query: "x", freshness: "pw"})

      assert %{"freshness" => "2025-01-01to2025-06-30"} =
               WardrikBrave.WebSearch.body(%{
                 query: "x",
                 published_between: "2025-01-01to2025-06-30"
               })
    end
  end

  test "asking for a window both ways is refused rather than half-honoured" do
    assert {:ok, %{"ok" => false, "error" => %{"message" => message}}} =
             WardrikBrave.WebSearch.run(
               %{query: "x", freshness: "pw", published_between: "2025-01-01to2025-06-30"},
               config()
             )

    assert message =~ "not both"
  end
end
