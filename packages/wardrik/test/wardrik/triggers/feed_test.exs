defmodule WardrikTriggers.FeedTest do
  use ExUnit.Case, async: true

  alias WardrikTriggers.Feed

  @rss """
  <?xml version="1.0"?>
  <rss version="2.0"><channel><title>Rivals</title>
    <item><title>Second</title><link>https://r.test/2</link><guid>r-2</guid><pubDate>Thu, 22 Oct 2026 09:00:00 GMT</pubDate><description><![CDATA[<p>New</p>]]></description></item>
    <item><title>First</title><link>https://r.test/1</link><guid>r-1</guid></item>
  </channel></rss>
  """

  @atom """
  <?xml version="1.0" encoding="utf-8"?>
  <feed xmlns="http://www.w3.org/2005/Atom"><title>Releases</title>
    <entry><id>tag:a,v2</id><title>v2</title><link rel="alternate" href="https://a.test/v2"/><updated>2026-10-22T09:00:00Z</updated><summary>Faster.</summary></entry>
  </feed>
  """

  test "reads an RSS feed's items and an Atom feed's entries" do
    assert {:ok,
            [
              %{
                id: "r-2",
                title: "Second",
                link: "https://r.test/2",
                date: "Thu, 22 Oct 2026 09:00:00 GMT",
                summary: "<p>New</p>"
              },
              %{id: "r-1", title: "First"}
            ]} = Feed.parse(@rss)

    assert {:ok, [%{id: "tag:a,v2", link: "https://a.test/v2", summary: "Faster."}]} =
             Feed.parse(@atom)

    assert {:error, "the feed doesn't read" <> _} = Feed.parse("<rss><item>")
  end

  test "finds the entries not seen before, oldest first" do
    {:ok, entries} = Feed.parse(@rss)

    assert {[%{id: "r-2"}], ["r-2", "r-1"]} = Feed.unseen(entries, ["r-1"])
    assert {[%{id: "r-1"}, %{id: "r-2"}], ["r-2", "r-1"]} = Feed.unseen(entries, [])
    assert {[], ["r-2", "r-1"]} = Feed.unseen(entries, ["r-2", "r-1"])
  end

  test "writes the entries under the prompt, twenty at most" do
    entries =
      for n <- 1..22, do: %{id: "#{n}", title: "Entry #{n}", link: nil, date: nil, summary: nil}

    prompt = Feed.prompt("What changed?", entries)

    assert prompt =~ "What changed?\n\nEntry 1\n\nEntry 2"
    assert prompt =~ "Entry 20\n\nAnd 2 more."
    refute prompt =~ "Entry 21"
  end
end
