defmodule WardrikBrave.WebSearch do
  @moduledoc """
  The `web_search` tool. Returns 10 results and about 4,096 tokens unless the agent asks for more.
  """

  alias WardrikBrave.Client

  @default_count 10
  @default_max_tokens 4_096
  @freshness ~w(pd pw pm py)
  @between ~r/\A\d{4}-\d{2}-\d{2}to\d{4}-\d{2}-\d{2}\z/

  @description """
  Search the web and get back the passages that bear on your query from the pages found, ready to read, not a list of links.

  Use it for anything you'd otherwise guess at: current facts, real companies and their prices, numbers, recent events, anything after your training. Prefer one specific query per thing you need over one broad query covering several.

  Answers each source's URL, title, passages, and the page's date where it's known. No results means nothing relevant was found, not that the search failed.
  """

  @doc "Returns the tool. `brave` is a started name or inline settings. See `WardrikBrave.settings/1`."
  @spec tool(atom() | map()) :: WardrikCore.Tool.t()
  def tool(brave) do
    WardrikCore.Tool.new!(
      name: "web_search",
      description: @description,
      schema: [
        query: [type: :string, required: true, doc: "What you want to know, as a search query"],
        count: [
          type: {:in, 1..50},
          doc:
            "How many results to consider, 10 unless set. 5 for a simple fact, 20 or more for research."
        ],
        freshness: [
          type: {:in, @freshness},
          doc:
            ~s("pd" the past day, "pw" week, "pm" month, "py" year. Leave it out for pages of any age.)
        ],
        published_between: [
          type: :string,
          doc:
            ~s(Only pages published in a window, as "2025-01-01to2025-06-30". Prefer freshness unless the dates matter.)
        ],
        max_tokens: [
          type: {:in, 1_024..32_768},
          doc:
            "About how many tokens the whole result may take, 4096 unless set. Raise it only for research."
        ]
      ],
      run: fn args, context -> run(brave, args, context) end,
      annotations: [read_only: true, idempotent: true, open_world: true, labels: ["outside"]]
    )
  end

  @doc """
  Runs one search. Returns `{:error, message}` for both `:freshness` and `:published_between`, or
  a `:published_between` that isn't `"YYYY-MM-DDtoYYYY-MM-DD"`.
  """
  @spec run(atom() | map(), map(), WardrikCore.Context.t()) ::
          {:ok, map()} | {:error, String.t()}
  def run(brave, args, context) do
    with {:ok, window} <- window(args),
         do: Client.search(settings(brave, context), body(args, window))
  end

  defp settings(brave, context) do
    case WardrikCore.Keys.fetch(context, "BRAVE_API_KEY") do
      {:ok, key} -> %{WardrikBrave.settings(brave) | api_key: key}
      {:error, _none} -> WardrikBrave.settings(brave)
    end
  end

  @doc "Returns the API parameters for the tool's arguments and date window."
  @spec body(map(), String.t() | nil) :: map()
  def body(args, window) do
    %{
      "q" => args[:query],
      "count" => args[:count] || @default_count,
      "maximum_number_of_tokens" => args[:max_tokens] || @default_max_tokens,
      "freshness" => window
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp window(%{freshness: _freshness, published_between: _between}),
    do: {:error, "Give freshness or published_between, not both."}

  defp window(%{published_between: between}) do
    if Regex.match?(@between, between),
      do: {:ok, between},
      else:
        {:error, ~s(published_between is "YYYY-MM-DDtoYYYY-MM-DD", as "2025-01-01to2025-06-30".)}
  end

  defp window(args), do: {:ok, args[:freshness]}
end
