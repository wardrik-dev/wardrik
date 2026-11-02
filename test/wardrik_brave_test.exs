defmodule WardrikBraveTest do
  use ExUnit.Case, async: true

  setup context do
    name = :"brave #{context.test}"
    key = Map.get(context, :key, "k3y")

    start_supervised!(
      {WardrikBrave, name: name, api_key: key, req_options: [plug: {Req.Test, name}]}
    )

    [tool] = WardrikBrave.tools(nil, brave: name)
    %{name: name, tool: tool}
  end

  defp search(tool, args), do: tool.run.(args, WardrikCore.Context.new(agent_id: "acme/triage"))

  test "answers the passages of each page found, with its date", %{name: name, tool: tool} do
    test = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:searched, Plug.Conn.get_req_header(conn, "x-subscription-token"), JSON.decode!(body)}
      )

      Req.Test.json(conn, %{
        "grounding" => %{
          "generic" => [
            %{"url" => "https://a.test", "title" => "A", "snippets" => ["one"]},
            %{"url" => "https://b.test"}
          ]
        },
        "sources" => %{"https://a.test" => %{"age" => ["October 1, 2026", "2026-10-01"]}}
      })
    end)

    assert search(tool, %{query: "elixir", freshness: "pw"}) ==
             {:ok,
              %{
                "count" => 2,
                "results" => [
                  %{
                    "url" => "https://a.test",
                    "title" => "A",
                    "snippets" => ["one"],
                    "age" => "October 1, 2026"
                  },
                  %{"url" => "https://b.test", "snippets" => []}
                ]
              }}

    assert_received {:searched, ["k3y"],
                     %{
                       "q" => "elixir",
                       "count" => 10,
                       "maximum_number_of_tokens" => 4096,
                       "freshness" => "pw"
                     }}
  end

  test "asks for an exact window, and refuses one that doesn't read", %{name: name, tool: tool} do
    Req.Test.stub(name, &Req.Test.json(&1, %{}))

    assert {:ok, %{"count" => 0}} =
             search(tool, %{
               query: "q",
               published_between: "2025-01-01to2025-06-30",
               count: 5,
               max_tokens: 2048
             })

    assert {:error, "Give freshness" <> _} =
             search(tool, %{query: "q", freshness: "pd", published_between: "x"})

    assert {:error, "published_between is" <> _} =
             search(tool, %{query: "q", published_between: "last week"})
  end

  test "says why a search failed", %{name: name, tool: tool} do
    Req.Test.stub(name, &Plug.Conn.send_resp(&1, 403, ""))
    assert {:error, "Brave's search answered 403."} = search(tool, %{query: "q"})

    Req.Test.stub(name, &Plug.Conn.send_resp(&1, 429, ""))
    assert_raise WardrikBrave.Unavailable, ~r/limiting/, fn -> search(tool, %{query: "q"}) end

    Req.Test.stub(name, &Plug.Conn.send_resp(&1, 500, ""))
    assert_raise WardrikBrave.Unavailable, ~r/answered 500/, fn -> search(tool, %{query: "q"}) end

    Req.Test.stub(name, &Req.Test.transport_error(&1, :econnrefused))

    assert_raise WardrikBrave.Unavailable, ~r/didn't answer/, fn ->
      search(tool, %{query: "q"})
    end

    Req.Test.stub(name, &Req.Test.text(&1, "not json"))
    assert {:ok, %{"count" => 0}} = search(tool, %{query: "q"})
  end

  defmodule Held do
    @behaviour WardrikCore.Keys

    @impl true
    def fetch(%{name: "BRAVE_API_KEY", principal: %WardrikCore.Principal{id: "acme"}}, _opts),
      do: {:ok, "acme-key"}

    def fetch(_request, _opts), do: {:error, :not_found}
  end

  test "searches with the agent's own key where its keys hold one", %{name: name, tool: tool} do
    test = self()

    Req.Test.stub(name, fn conn ->
      send(test, {:token, Plug.Conn.get_req_header(conn, "x-subscription-token")})
      Req.Test.json(conn, %{"grounding" => %{"generic" => []}, "sources" => %{}})
    end)

    context =
      WardrikCore.Context.new(
        agent_id: "acme/triage",
        principal: %WardrikCore.Principal{id: "acme"},
        keys: {Held, []}
      )

    assert {:ok, _found} = tool.run.(%{query: "q"}, context)
    assert_receive {:token, ["acme-key"]}

    assert {:ok, _found} = search(tool, %{query: "q"})
    assert_receive {:token, ["k3y"]}
  end

  test "searches with settings given inline, and the agent's own key, with nothing started" do
    test = self()

    Req.Test.stub(:inline, fn conn ->
      send(test, {:token, Plug.Conn.get_req_header(conn, "x-subscription-token")})
      Req.Test.json(conn, %{"grounding" => %{"generic" => []}, "sources" => %{}})
    end)

    [tool] = WardrikBrave.tools(nil, req_options: [plug: {Req.Test, :inline}])

    context =
      WardrikCore.Context.new(
        agent_id: "acme/triage",
        principal: %WardrikCore.Principal{id: "acme"},
        keys: {Held, []}
      )

    assert {:ok, _found} = tool.run.(%{query: "q"}, context)
    assert_receive {:token, ["acme-key"]}

    assert {:error, "Web search has no key." <> _} = search(tool, %{query: "q"})
  end

  @tag key: nil
  test "says the key is missing", %{tool: tool} do
    assert {:error, "Web search has no key." <> _} = search(tool, %{query: "q"})
  end

  test "marks the tool as reaching the open world", %{tool: tool} do
    assert WardrikCore.Tool.annotation(tool, :open_world)
    assert WardrikCore.Tool.annotation(tool, :labels) == ["outside"]
  end

  test "says which one isn't started" do
    assert_raise ArgumentError, ~r/isn't started/, fn -> WardrikBrave.settings(:nowhere) end
  end
end
