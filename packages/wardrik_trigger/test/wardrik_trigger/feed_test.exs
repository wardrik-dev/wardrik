defmodule WardrikTrigger.FeedTest do
  use ExUnit.Case, async: true

  alias WardrikTrigger.Feed
  alias WardrikTrigger.Item

  @agent Wardrik.AgentID.parse!("acme/growth")
  @rss "https://example.com/rss"
  @atom "https://example.com/atom"

  defp rss(items) do
    """
    <?xml version="1.0"?>
    <rss version="2.0"><channel><title>Rivalco</title>
    #{Enum.map_join(items, "\n", &rss_item/1)}
    </channel></rss>
    """
  end

  defp rss_item({id, title}) do
    """
    <item>
      <guid>#{id}</guid>
      <title>#{title}</title>
      <link>https://example.com/#{id}</link>
      <pubDate>Mon, 12 Oct 2026 08:00:00 +0200</pubDate>
      <description><![CDATA[<p>Launched a <b>free</b> plan &amp; more.</p>]]></description>
    </item>
    """
  end

  defp atom(entries) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"><title>Billwise</title>
    #{Enum.map_join(entries, "\n", fn {id, title} -> """
      <entry>
        <id>urn:billwise:#{id}</id>
        <title>#{title}</title>
        <link rel="alternate" href="https://billwise.example/#{id}"/>
        <updated>2026-10-12T08:00:00Z</updated>
        <summary>#{title}, in short.</summary>
      </entry>
      """ end)}
    </feed>
    """
  end

  # Answers each feed's URL with what `bodies` holds for it now.
  defp serve(bodies) do
    Req.Test.stub(Feed, fn conn ->
      case Map.fetch(bodies, "https://example.com" <> conn.request_path) do
        {:ok, {status, body}} -> Plug.Conn.send_resp(conn, status, body)
        {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
        :error -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  describe "decode/1 and encode/1" do
    test "read a URL, or a list of them, and write them back" do
      assert {:ok, [@rss]} = Feed.decode(%{"feed" => @rss})
      assert Feed.encode([@rss]) == %{"feed" => @rss}
      assert {:ok, [@rss, @atom]} = Feed.decode(%{"feed" => [@rss, @atom]})
      assert Feed.encode([@rss, @atom]) == %{"feed" => [@rss, @atom]}
    end

    test "say what does not read" do
      for feed <- ["example.com/rss", [], [@rss, 3], %{"url" => @rss}] do
        assert Feed.decode(%{"feed" => feed}) == {:error, "feed is a URL, or a list of them"}
      end

      assert Feed.decode(%{"feed" => @rss, "since" => "today"}) ==
               {:error, "since is not a setting of a feed"}
    end

    test "are what a trigger written as text names by feed" do
      assert {:ok, %WardrikTrigger{source: {Feed, [@rss]}}} =
               WardrikTrigger.decode("rivals", %{
                 "every" => "1h",
                 "prompt" => "New?",
                 "feed" => @rss
               })
    end
  end

  describe "check/3" do
    test "only reads a feed the first time, and finds what it adds after" do
      serve(%{@rss => rss([{"1", "Old news"}])})
      assert {:ok, [], cursor} = Feed.check([@rss], nil, @agent)

      serve(%{@rss => rss([{"2", "Free plan"}, {"1", "Old news"}])})
      assert {:ok, [item], cursor} = Feed.check([@rss], cursor, @agent)

      assert %Item{
               id: "2",
               title: "Free plan",
               link: "https://example.com/2",
               at: ~U[2026-10-12 06:00:00Z],
               text: "Launched a free plan & more.",
               labels: ["outside"]
             } = item

      assert {:ok, [], _cursor} = Feed.check([@rss], cursor, @agent)
    end

    test "names an entry by its link where it has no guid, and clips a long summary" do
      long = String.duplicate("word ", 200)

      body = """
      <rss version="2.0"><channel>
        <item><link>https://example.com/0</link><title>Seed</title></item>
      </channel></rss>
      """

      serve(%{@rss => body})
      {:ok, [], cursor} = Feed.check([@rss], nil, @agent)

      serve(%{
        @rss => """
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel>
          <item>
            <link>https://example.com/3</link>
            <title>Pricing</title>
            <dc:date>2026-10-12T09:30:00Z</dc:date>
            <description>#{long}</description>
          </item>
          <item>
            <link>https://example.com/4</link>
            <pubDate>Mon, 12 Oct 2026 10:00 GMT</pubDate>
          </item>
        </channel></rss>
        """
      })

      assert {:ok, [pricing, untitled], _cursor} = Feed.check([@rss], cursor, @agent)
      assert %Item{id: "https://example.com/3", at: ~U[2026-10-12 09:30:00Z]} = pricing
      assert String.length(pricing.text) == 501
      assert String.ends_with?(pricing.text, "…")

      assert %Item{id: "https://example.com/4", title: nil, at: ~U[2026-10-12 10:00:00Z]} =
               untitled
    end

    test "reads Atom" do
      serve(%{@atom => atom([{"a", "Old"}])})
      {:ok, [], cursor} = Feed.check([@atom], nil, @agent)

      serve(%{@atom => atom([{"b", "Seats"}, {"a", "Old"}])})

      assert {:ok,
              [
                %Item{
                  id: "urn:billwise:b",
                  title: "Seats",
                  link: "https://billwise.example/b",
                  at: ~U[2026-10-12 08:00:00Z],
                  text: "Seats, in short."
                }
              ], _cursor} = Feed.check([@atom], cursor, @agent)
    end

    test "asks again with the ETag and Last-Modified a feed answered with" do
      test = self()

      Req.Test.stub(Feed, fn conn ->
        send(test, {:asked, Plug.Conn.get_req_header(conn, "if-none-match")})

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("v1"))
        |> Plug.Conn.put_resp_header("last-modified", "Mon, 12 Oct 2026 08:00:00 GMT")
        |> Plug.Conn.send_resp(200, rss([{"1", "Old news"}]))
      end)

      {:ok, [], cursor} = Feed.check([@rss], nil, @agent)
      assert_receive {:asked, []}

      Req.Test.stub(Feed, fn conn ->
        send(test, {:asked, Plug.Conn.get_req_header(conn, "if-none-match")})
        Plug.Conn.send_resp(conn, 304, "")
      end)

      assert {:ok, [], ^cursor} = Feed.check([@rss], cursor, @agent)
      assert_receive {:asked, [~s("v1")]}
    end

    test "reads the feeds it can, and fails only where it can read none" do
      serve(%{@rss => rss([{"1", "Old news"}])})
      {:ok, [], cursor} = Feed.check([@rss, @atom], nil, @agent)
      assert Map.keys(cursor) == [@rss]

      serve(%{@rss => {500, "down"}, @atom => "not a feed"})

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, reason} = Feed.check([@rss, @atom], cursor, @agent)
        assert reason =~ "#{@rss}: it answered 500"
        assert reason =~ "#{@atom}: it is not RSS or Atom"
      end)
    end
  end
end
