defmodule WardrikDaemon.HelpTools do
  @moduledoc """
  The `help` tools: an agent answers how Wardrik works and where this deployment keeps things.

      tools: [help]

  | Tool | What it does |
  | --- | --- |
  | `wardrik_about` | This deployment's version, org, URLs, and where its config, agent files, keys, store and logs are. |
  | `wardrik_doctor` | Runs the checks `wardrik doctor` runs: the config, keys, MCP servers, channels and agent files. |
  | `docs_search` | Finds the documentation pages that answer a question, with each page's URL. |
  | `docs_read` | Reads one documentation page as Markdown. |

  The documentation comes from `docs`, `https://docs.wardrik.dev/pages.json` unless set. It's
  fetched on first use and kept for an hour. If fetching fails, the last copy is used.
  """

  @behaviour WardrikCore.Capability

  alias WardrikCore.Tool
  alias WardrikDaemon.Config
  alias WardrikDaemon.Dirs

  @docs "https://docs.wardrik.dev/pages.json"
  @kept :timer.hours(1)
  @found 5
  @longest 40_000

  @impl WardrikCore.Capability
  def tools(_context, opts) do
    daemon = Keyword.fetch!(opts, :daemon)
    docs = %{url: Keyword.get(opts, :docs, @docs), req: Keyword.get(opts, :req_options, [])}

    [
      Tool.new!(
        name: "wardrik_about",
        description:
          "Read this Wardrik deployment's version, org and URLs, and where its config.yaml, agent files, env file, keys, store and logs are.",
        schema: %{"type" => "object", "properties" => %{}},
        run: fn _args, _context -> {:ok, about(daemon)} end,
        annotations: [read_only: true, idempotent: true]
      ),
      Tool.new!(
        name: "wardrik_doctor",
        description:
          "Check this deployment as wardrik doctor does: its env file, config.yaml, vault, MCP servers, channels, harnesses and agent files. Answers each check as ok, warn or fail, with what it found.",
        schema: %{"type" => "object", "properties" => %{}},
        run: fn _args, _context -> {:ok, %{"checks" => checks(daemon.env)}} end,
        annotations: [read_only: true, idempotent: true, timeout: 60_000]
      ),
      Tool.new!(
        name: "docs_search",
        description:
          "Search Wardrik's documentation. Answers the pages that best match, each with its title, URL and description. Read a page with docs_read before you answer from it, and give the person its URL.",
        schema: %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "What to look for, as triggers or edit an agent file"
            }
          }
        },
        run: fn %{"query" => query}, _context -> with_pages(docs, &search(&1, query)) end,
        annotations: [read_only: true, idempotent: true, open_world: true]
      ),
      Tool.new!(
        name: "docs_read",
        description:
          "Read a page of Wardrik's documentation as Markdown, by the URL docs_search gave.",
        schema: %{
          "type" => "object",
          "required" => ["url"],
          "properties" => %{"url" => %{"type" => "string", "description" => "The page's URL"}}
        },
        run: fn %{"url" => url}, _context -> with_pages(docs, &read(&1, url)) end,
        annotations: [read_only: true, idempotent: true, open_world: true]
      )
    ]
  end

  defp about(%{config: config, dirs: %Dirs{} = dirs, web: web}) do
    url = Config.base_url(config)

    %{
      "version" => to_string(Application.spec(:wardrik_daemon, :vsn)),
      "org" => config.org,
      "url" => url,
      "dashboard" => web && String.trim_trailing(url, "/") <> "/web",
      "config_file" => Dirs.config(dirs, "config.yaml"),
      "agent_files" => Dirs.config(dirs, "agents"),
      "policy_files" => Dirs.config(dirs, "policies"),
      "env_file" => dirs.env_file,
      "keys" => dirs.data_home,
      "store" => store(config, dirs),
      "logs" => dirs.state,
      "docs" => "https://docs.wardrik.dev"
    }
  end

  defp checks(env) do
    for {status, check, found} <- WardrikDaemon.Doctor.run(env),
        do: %{"status" => to_string(status), "check" => check, "found" => found}
  end

  defp store(%Config{storage: nil}, dirs), do: "on this machine's disk, in #{dirs.data}"
  defp store(%Config{storage: {kind, _settings}}, _dirs), do: "in #{kind}"

  defp search(pages, query) do
    words = query |> String.downcase() |> String.split(~r/\W+/u, trim: true)

    found =
      pages
      |> Enum.map(&{score(&1, words), &1})
      |> Enum.filter(fn {score, _page} -> score > 0 end)
      |> Enum.sort_by(fn {score, _page} -> score end, :desc)
      |> Enum.take(@found)
      |> Enum.map(fn {_score, page} -> Map.take(page, ["title", "url", "description"]) end)

    {:ok, %{"pages" => found}}
  end

  # A word in the title counts most, then the description, then each time the page says it.
  defp score(page, words) do
    title = String.downcase(page["title"])
    description = String.downcase(page["description"] || "")
    body = String.downcase(page["markdown"])

    Enum.sum_by(words, fn word ->
      count(title, word) * 10 + count(description, word) * 4 + min(count(body, word), 10)
    end)
  end

  defp count(text, word), do: text |> String.split(word) |> length() |> Kernel.-(1)

  defp read(pages, url) do
    case Enum.find(pages, &(&1["url"] == url or String.trim_trailing(&1["url"], "/") == url)) do
      nil ->
        {:error, "There's no page #{url}. Use a URL docs_search gave."}

      page ->
        {:ok,
         %{
           "title" => page["title"],
           "url" => page["url"],
           "markdown" => String.slice(page["markdown"], 0, @longest)
         }}
    end
  end

  defp with_pages(docs, fun) do
    case pages(docs) do
      {:ok, pages} ->
        fun.(pages)

      :error ->
        {:error,
         "The documentation at #{docs.url} didn't load. It's also at https://docs.wardrik.dev."}
    end
  end

  # Kept in persistent_term: it changes about once an hour, and every turn reads it.
  defp pages(%{url: url} = docs) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, url}, nil) do
      {at, pages} when now - at < @kept -> {:ok, pages}
      kept -> fetched(docs, now, kept)
    end
  end

  defp fetched(%{url: url, req: req}, now, kept) do
    case Req.get(url, [retry: false] ++ req) do
      {:ok, %Req.Response{status: 200, body: %{"pages" => pages}}} ->
        :persistent_term.put({__MODULE__, url}, {now, pages})
        {:ok, pages}

      _failed ->
        case kept do
          {_at, pages} -> {:ok, pages}
          nil -> :error
        end
    end
  end
end
