defmodule WardrikBrave.WebSearch do
  @moduledoc """
  Web search for agents, backed by Brave's LLM Context API.

      Wardrik.LLM.Config.new(tools: [WardrikBrave.WebSearch])

  Returns extracted page content rather than links, so one call is enough to
  ground an answer. Token budgets are deliberately smaller than the API's
  defaults: a tool result becomes part of the calling turn's context, and an
  agent that runs three searches at 8k tokens each has spent its window on
  search results.

  What it answers is pages anyone could have written, so a call to it taints
  its run; see `c:Wardrik.Tool.outside_content?/1`.
  """

  @behaviour Wardrik.Tool

  alias Wardrik.Tool.Result
  alias WardrikBrave.Client
  alias WardrikBrave.Config

  @default_count 10
  @default_max_tokens 4_096

  @count 1..50
  @max_tokens 1_024..32_768
  @freshness ~w(pd pw pm py)
  @between ~r/^\d{4}-\d{2}-\d{2}to\d{4}-\d{2}-\d{2}$/

  @description """
  Search the web and get back the relevant passages from the pages found, ready to read, not a list of links.

  Use it for anything you would otherwise be guessing at: current facts, real companies and their pricing, numbers, recent events, anything after your training cutoff. Prefer one specific query per thing you need to know over one broad query covering several.

  Returns each source's URL, title, extracted passages, and the page's date where it is known. An empty result means nothing relevant was found, not that the search failed.
  """

  @doc "The pages a search finds are content from outside."
  @impl true
  def outside_content?(_name), do: true

  @impl true
  def tool do
    ReqLLM.Tool.new!(
      name: "web_search",
      description: @description,
      parameter_schema: [
        query: [
          type: :string,
          required: true,
          doc: "What you want to know, phrased as a search query"
        ],
        count: [
          type: {:in, @count},
          doc:
            "How many results to consider. Defaults to #{@default_count}. Use 5 for a simple fact, 20+ for research."
        ],
        freshness: [
          type: {:in, @freshness},
          doc:
            ~s("pd" past day, "pw" past week, "pm" past month, "py" past year. Leave it out to search pages of any age. For an exact window use published_between instead.)
        ],
        published_between: [
          type: {:custom, __MODULE__, :validate_between, []},
          doc:
            ~s(Restrict to pages published in an exact window, as "YYYY-MM-DDtoYYYY-MM-DD" — for example "2025-01-01to2025-06-30". Prefer freshness unless the dates matter.)
        ],
        max_tokens: [
          type: {:in, @max_tokens},
          doc:
            "Approximate token budget for the whole result. Defaults to #{@default_max_tokens}. Raise it only for research."
        ]
      ],
      callback: {__MODULE__, :run}
    )
  end

  @doc """
  Checks a `published_between` window.

  A `t:NimbleOptions.type/0` callback, so a malformed window is refused with a
  sentence naming the format rather than becoming a rejected request.
  """
  @spec validate_between(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_between(value) when is_binary(value) do
    if Regex.match?(@between, value) do
      {:ok, value}
    else
      {:error,
       ~s(expected "YYYY-MM-DDtoYYYY-MM-DD", for example "2025-01-01to2025-06-30", got: #{inspect(value)})}
    end
  end

  def validate_between(value), do: {:error, "expected a string, got: #{inspect(value)}"}

  @doc "Runs one search and reports the outcome to the model."
  @spec run(map() | keyword()) :: Result.t()
  def run(params) do
    case window(Map.new(params)) do
      {:ok, _window} -> search(params)
      {:error, message} -> Result.error(:conflicting_dates, message)
    end
  end

  defp search(params) do
    case Client.search(Config.new(), body(params)) do
      {:ok, result} -> Result.ok(result)
      {:error, reason} -> Result.error(reason)
    end
  end

  # Brave takes one field, so the two ways of asking for it are exclusive.
  defp window(%{freshness: _, published_between: _}) do
    {:error, "give either freshness or published_between, not both"}
  end

  defp window(params),
    do: {:ok, Map.get(params, :freshness) || Map.get(params, :published_between)}

  @doc """
  Maps the tool's arguments onto the API's.

  Pure, and the only place the defaults live.
  """
  @spec body(map() | keyword()) :: map()
  def body(params) do
    params = Map.new(params)

    %{
      "q" => Map.get(params, :query),
      "count" => Map.get(params, :count) || @default_count,
      "maximum_number_of_tokens" => Map.get(params, :max_tokens) || @default_max_tokens,
      "freshness" => Map.get(params, :freshness) || Map.get(params, :published_between)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
