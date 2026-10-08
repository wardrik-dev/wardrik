defmodule WardrikBrave.Client do
  @moduledoc """
  Brave's LLM Context API: web search that returns page content, not links.

  The endpoint ranks and extracts the passages relevant to a query and returns
  them ready to read, so an agent grounds an answer in one call rather than
  searching, choosing a link, fetching it, and stripping the HTML.

  `summarize/1` reduces the response to the fields a model can use, which keeps
  a result small enough that several searches fit in one turn.
  """

  alias WardrikBrave.Config

  @path "/res/v1/llm/context"
  # Brave's own guidance. A search that has not answered in 30s will not.
  @receive_timeout 30_000

  @doc """
  Runs one search.

  `params` are the API's own query parameters, `q` required. Returns
  `{:error, :missing_brave_api_key}` when the config has no key, which is a
  configuration problem rather than a search that found nothing.
  """
  @spec search(Config.t(), map()) :: {:ok, map()} | {:error, term()}
  def search(%Config{} = config, params) when is_map(params) do
    if Config.usable?(config), do: post(config, params), else: {:error, :missing_brave_api_key}
  end

  defp post(%Config{} = config, params) do
    options =
      [json: params, headers: headers(config), receive_timeout: @receive_timeout]
      |> Keyword.merge(config.req_options)

    case Req.post(config.base_url <> @path, options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, summarize(body)}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :brave_rate_limited}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Brave search failed, status: #{status}, body: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Brave search failed, reason: #{inspect(reason)}"}
    end
  end

  @doc "The auth header the endpoint expects."
  @spec headers(Config.t()) :: map()
  def headers(%Config{} = config),
    do: %{"x-subscription-token" => config.api_key, "accept" => "application/json"}

  @doc """
  Reduces a response to what a model can act on.

  Pure. Keeps the URL, the title, the extracted passages, and the page's date
  where Brave knows one, and drops the rest. No results is a successful search
  that found nothing, not a failure.
  """
  @spec summarize(map()) :: map()
  def summarize(body) when is_map(body) do
    sources = Map.get(body, "sources", %{})

    results =
      body
      |> Map.get("grounding", %{})
      |> grounding_generic()
      |> Enum.map(&result(&1, sources))

    %{"results" => results, "count" => length(results)}
  end

  def summarize(_body), do: %{"results" => [], "count" => 0}

  defp grounding_generic(%{"generic" => generic}) when is_list(generic), do: generic
  defp grounding_generic(_grounding), do: []

  defp result(entry, sources) when is_map(entry) do
    url = Map.get(entry, "url")

    %{
      "url" => url,
      "title" => Map.get(entry, "title"),
      "snippets" => Map.get(entry, "snippets", []),
      "age" => age(sources, url)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp result(entry, _sources), do: %{"snippets" => [], "value" => inspect(entry)}

  # `age` is four renderings of one date in fixed positions; the first is the
  # human one and the only one worth spending tokens on.
  defp age(sources, url) when is_binary(url) do
    case sources do
      %{^url => %{"age" => [readable | _rest]}} -> readable
      _sources -> nil
    end
  end

  defp age(_sources, _url), do: nil
end
