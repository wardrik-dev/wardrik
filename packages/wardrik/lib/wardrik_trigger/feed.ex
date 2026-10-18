defmodule WardrikTrigger.Feed do
  @moduledoc """
  The `feed` source: one or more RSS or Atom feeds, asked for what is new on
  each run.

      %{"every" => "1h", "feed" => "https://example.com/feed.xml", "prompt" => "What is new?"}
      %{"every" => "6h", "feed" => ["https://a.example/rss", "https://b.example/atom"], "prompt" => "..."}

  Each entry is a `WardrikTrigger.Item`, labelled `"outside"`: its id is the
  entry's `guid` or `id`, or its link, and it shows the agent the entry's
  title, link, time and summary, with the summary's markup taken out.

  The cursor is, for each feed, the ids it has seen, its newest 500, and the
  `ETag` and `Last-Modified` it last answered with, sent back so a feed that
  has not changed answers with nothing. A feed checked for the first time is
  only read: what it already holds is seen, and only what it adds after is
  new.

  A feed that cannot be read is logged and checked again next time, while the
  others are read as usual; the run fails only where none could be read.
  The `:req_options` of the settings the host starts the triggers with for
  this source are merged into every request; see `WardrikTrigger.start_link/1`.
  """

  @behaviour WardrikTrigger.Source

  import SweetXml, only: [sigil_x: 2]

  alias WardrikTrigger.Item

  require Logger

  @seen 500
  @summary 500

  @impl WardrikTrigger.Source
  def decode(%{"feed" => url} = fields) when map_size(fields) == 1 and is_binary(url),
    do: decode(%{"feed" => [url]})

  def decode(%{"feed" => [_ | _] = urls} = fields) when map_size(fields) == 1 do
    if Enum.all?(urls, &url?/1),
      do: {:ok, urls},
      else: {:error, "feed is a URL, or a list of them"}
  end

  def decode(%{"feed" => _other} = fields) when map_size(fields) == 1,
    do: {:error, "feed is a URL, or a list of them"}

  def decode(fields) do
    key = fields |> Map.keys() |> Enum.reject(&(&1 == "feed")) |> Enum.min()
    {:error, "#{key} is not a setting of a feed"}
  end

  defp url?(url) do
    is_binary(url) and
      match?(
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host),
        URI.parse(url)
      )
  end

  @impl WardrikTrigger.Source
  def encode([url]), do: %{"feed" => url}
  def encode(urls), do: %{"feed" => urls}

  @impl WardrikTrigger.Source
  def check(urls, cursor, opts) do
    req_options = opts |> Keyword.get(:settings, []) |> Keyword.get(:req_options, [])
    cursor = cursor || %{}
    read = Enum.map(urls, &{&1, read(&1, Map.get(cursor, &1), req_options)})

    case Enum.reject(read, &match?({_url, {:error, _reason}}, &1)) do
      [] ->
        {:error, read |> Enum.map(&failure/1) |> Enum.intersperse("; ") |> IO.iodata_to_binary()}

      _read ->
        {:ok, Enum.flat_map(read, &found/1), Enum.reduce(read, cursor, &kept/2)}
    end
  end

  defp failure({url, {:error, reason}}), do: [url, ": ", reason]

  defp found({_url, {:ok, items, _state}}), do: items
  defp found({_url, {:error, _reason}}), do: []

  defp kept({url, {:ok, _items, state}}, cursor), do: Map.put(cursor, url, state)
  defp kept({_url, {:error, _reason}}, cursor), do: cursor

  defp read(url, state, req_options) do
    with {:error, reason} = failed <- fetched(url, state, req_options) do
      Logger.warning("feed #{url} could not be read: #{reason}")
      failed
    end
  end

  # What a feed holds that `state` has not seen, and the state after.
  defp fetched(url, state, req_options) do
    case fetch(url, state, req_options) do
      {:ok, :unchanged} ->
        {:ok, [], state}

      {:ok, body, headers} ->
        with {:ok, entries} <- entries(body),
             do: {:ok, new(entries, state), seen(entries, state, headers)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp new(_entries, nil), do: []
  defp new(entries, state), do: Enum.reject(entries, &(&1.id in state.seen))

  defp seen(entries, state, headers) do
    %{
      seen: Enum.take(Enum.uniq(Enum.map(entries, & &1.id) ++ ids(state)), @seen),
      etag: header(headers, "etag"),
      modified: header(headers, "last-modified")
    }
  end

  defp ids(nil), do: []
  defp ids(state), do: state.seen

  defp fetch(url, state, req_options) do
    options =
      Keyword.merge([url: url, headers: conditional(state), decode_body: false], req_options)

    case Req.get(options) do
      {:ok, %Req.Response{status: 304}} -> {:ok, :unchanged}
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} -> {:ok, body, headers}
      {:ok, %Req.Response{status: status}} -> {:error, "it answered #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp conditional(nil), do: []

  defp conditional(state) do
    [{"if-none-match", state.etag}, {"if-modified-since", state.modified}]
    |> Enum.reject(&match?({_name, nil}, &1))
  end

  defp header(headers, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      _none -> nil
    end
  end

  # -- parsing -----------------------------------------------------------------

  defp entries(body) do
    doc = SweetXml.parse(body, dtd: :none, quiet: true)

    case SweetXml.xpath(doc, ~x"//*[local-name()='item']"l) do
      [] -> {:ok, doc |> SweetXml.xpath(~x"//*[local-name()='entry']"l) |> Enum.map(&atom/1)}
      items -> {:ok, Enum.map(items, &rss/1)}
    end
  catch
    :exit, _reason -> {:error, "it is not RSS or Atom"}
  end

  defp rss(node) do
    link = text(node, "link")

    item(
      text(node, "guid") || link || text(node, "title"),
      text(node, "title"),
      link,
      rfc822(text(node, "pubDate")) || iso8601(text(node, "date")),
      text(node, "description") || text(node, "encoded")
    )
  end

  defp atom(node) do
    link =
      SweetXml.xpath(node, ~x"./*[local-name()='link'][@rel='alternate' or not(@rel)]/@href"s)
      |> blank()

    item(
      text(node, "id") || link || text(node, "title"),
      text(node, "title"),
      link,
      iso8601(text(node, "updated") || text(node, "published")),
      text(node, "summary") || text(node, "content")
    )
  end

  defp item(id, title, link, at, summary) do
    %Item{
      id: id,
      title: title,
      link: link,
      at: at,
      text: summary && summary |> plain() |> clip(),
      labels: ["outside"]
    }
  end

  # An element's text by its name in whatever namespace the feed puts it, as
  # Atom and RSS's extensions do.
  defp text(node, name),
    do:
      node
      |> SweetXml.xpath(SweetXml.sigil_x("string(./*[local-name()='#{name}'])", ~c"s"))
      |> blank()

  defp blank(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp plain(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~w(&amp; &lt; &gt; &quot; &#39; &nbsp;), fn
      "&amp;" -> "&"
      "&lt;" -> "<"
      "&gt;" -> ">"
      "&quot;" -> "\""
      "&#39;" -> "'"
      "&nbsp;" -> " "
    end)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp clip(text) when byte_size(text) <= @summary, do: text
  defp clip(text), do: String.slice(text, 0, @summary) <> "…"

  defp iso8601(nil), do: nil

  defp iso8601(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # RSS's dates, as RFC 822 writes them: `Mon, 12 Oct 2026 08:00:00 GMT`.
  defp rfc822(nil), do: nil

  defp rfc822(text) do
    with [_, day, month, year, time, zone] <-
           Regex.run(
             ~r/^(?:\w+,\s*)?(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}:\d{2}(?::\d{2})?)\s*(\S+)?/,
             text
           ),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), index + 1, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(if(byte_size(time) == 5, do: time <> ":00", else: time)),
         {:ok, at} <- DateTime.new(date, time) do
      DateTime.add(at, -offset(zone), :second)
    else
      _unread -> nil
    end
  end

  defp offset(<<sign, hours::binary-size(2), minutes::binary-size(2)>>) when sign in [?+, ?-] do
    seconds = String.to_integer(hours) * 3_600 + String.to_integer(minutes) * 60
    if sign == ?+, do: seconds, else: -seconds
  end

  defp offset(_zone), do: 0
end
