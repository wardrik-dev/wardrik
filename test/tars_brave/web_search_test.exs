defmodule TarsBrave.WebSearchTest do
  use TarsBrave.Case, async: true

  alias TarsBrave.WebSearch

  @body %{"grounding" => %{"generic" => [%{"url" => "https://a.test", "snippets" => ["hi"]}]}}

  describe "tool/0" do
    test "declares a web_search tool the model can call" do
      tool = WebSearch.tool()

      assert %ReqLLM.Tool{name: "web_search"} = tool
      assert tool.description =~ "Search the web"
      assert tool.callback == {WebSearch, :run}
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

  describe "run/1" do
    test "a search reports its results under ok" do
      stub_json(200, @body)

      assert {:ok, %{"ok" => true, "result" => result}} = WebSearch.run(%{query: "elixir"})
      assert result["count"] == 1
    end

    test "a failed search is a result the model can read, not a failed tool" do
      stub_status(429)

      assert {:ok, %{"ok" => false, "error" => error}} = WebSearch.run(%{query: "elixir"})
      assert error["code"] == "brave_rate_limited"
    end

    test "executing through the tool runs the same path" do
      stub_json(200, @body)

      assert {:ok, %{"ok" => true}} =
               ReqLLM.Tool.execute(WebSearch.tool(), %{query: "elixir"})
    end
  end
end
