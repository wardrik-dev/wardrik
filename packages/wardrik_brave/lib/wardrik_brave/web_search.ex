defmodule WardrikBrave.WebSearch do
  @moduledoc """
  Web search for agents, backed by Brave's LLM Context API.

      Wardrik.LLM.Config.new(tools: [WardrikBrave.WebSearch])

  Returns extracted page content rather than links, so one call is enough to
  ground an answer. Token budgets are deliberately smaller than the API's
  defaults: a tool result becomes part of the calling turn's context, and an
  agent that runs three searches at 8k tokens each has spent its window on
  search results.

  What it answers is pages anyone could have written, so it is labelled
  `"outside"`; see `Wardrik.Tool.Annotations`.

  Its key is the credential `BRAVE_API_KEY`, which the scope's
  `Wardrik.Credential` resolver resolves for each call, such as `WardrikVault`
  holding it as the deployment's secret.

  Brave bills each query. Named with what one costs on the deployment's plan,
  in US dollars, every search says so, and a budget counts it:

      Wardrik.LLM.Config.new(tools: [{WardrikBrave.WebSearch, price: 0.005}])
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

  @credential "BRAVE_API_KEY"

  @doc "The pages a search finds are content from outside, and a search needs the key."
  @impl true
  def annotations(_name), do: %{labels: ["outside"], credentials: [@credential]}

  @impl true
  def annotations(_opts, name), do: annotations(name)

  @doc "The tool, as named with `price:`, what one search costs in US dollars."
  @impl true
  def tools(opts) when is_list(opts), do: [tool(Keyword.get(opts, :price))]

  @impl true
  def tool, do: tool(nil)

  defp tool(price) when is_nil(price) or (is_number(price) and price >= 0) do
    Wardrik.Tool.new!(
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
      run: {__MODULE__, :run, [price]}
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

  @doc """
  Runs one search and reports the outcome to the model, and what it cost at
  `price`, where one is named: with the key the call resolved, handed its
  `Wardrik.Tool.Context`, or as `config` says.
  """
  @spec run(number() | nil, map() | keyword(), Wardrik.Tool.Context.t() | Config.t()) ::
          Result.t()
  def run(price \\ nil, params, context)

  def run(price, params, %Wardrik.Tool.Context{credentials: credentials}),
    do: run(price, params, Config.new(api_key: key(credentials[@credential])))

  def run(price, params, %Config{} = config) do
    case window(Map.new(params)) do
      {:ok, _window} -> search(params, config, price)
      {:error, message} -> Result.error(:conflicting_dates, message)
    end
  end

  defp key(nil), do: nil
  defp key(credential), do: Wardrik.Credential.reveal(credential)

  defp search(params, config, price) do
    case Client.search(config, body(params)) do
      {:ok, result} -> Result.ok(result, cost: price)
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
