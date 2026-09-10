defmodule TarsBrave.WebSearch do
  @moduledoc """
  Web search for agents, backed by Brave's LLM Context API.

      Tars.LLM.Config.new(tools: [TarsBrave.WebSearch])

  Returns extracted page content rather than links, so one call is enough to
  ground an answer. Token budgets are deliberately smaller than the API's
  defaults: a tool result becomes part of the calling turn's context, and an
  agent that runs three searches at 8k tokens each has spent its window on
  search results.
  """

  @behaviour Tars.Tool

  alias Tars.Tool.Result
  alias TarsBrave.Client
  alias TarsBrave.Config

  @default_count 10
  @default_max_tokens 4_096

  @description """
  Search the web and get back the relevant passages from the pages found, ready to read, not a list of links.

  Use it for anything you would otherwise be guessing at: current facts, real companies and their pricing, numbers, recent events, anything after your training cutoff. Prefer one specific query per thing you need to know over one broad query covering several.

  Returns each source's URL, title, extracted passages, and the page's date where it is known. An empty result means nothing relevant was found, not that the search failed.
  """

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
          type: :integer,
          doc:
            "How many results to consider, 1-50. Defaults to 10. Use 5 for a simple fact, 20+ for research."
        ],
        freshness: [
          type: :string,
          doc:
            ~s(Restrict to recent pages: "pd" past day, "pw" past week, "pm" past month, "py" past year, or "YYYY-MM-DDtoYYYY-MM-DD".)
        ],
        max_tokens: [
          type: :integer,
          doc:
            "Approximate token budget for the whole result, 1024-32768. Defaults to 4096. Raise it only for research."
        ]
      ],
      callback: {__MODULE__, :run}
    )
  end

  @doc "Runs one search and reports the outcome to the model."
  @spec run(map() | keyword()) :: Result.t()
  def run(params) do
    case Client.search(Config.new(), body(params)) do
      {:ok, result} -> Result.ok(result)
      {:error, reason} -> Result.error(reason)
    end
  end

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
      "freshness" => Map.get(params, :freshness)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
