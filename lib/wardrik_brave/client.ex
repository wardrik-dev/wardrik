defmodule WardrikBrave.Client do
  @moduledoc """
  Calls Brave's LLM Context API, keeping each result's URL, title, passages and date.

  Raises `WardrikBrave.Unavailable` on a rate limit, a 5xx or a dropped connection, so the tool
  runner retries.
  """

  @path "/res/v1/llm/context"
  @receive_timeout 30_000

  @doc """
  Runs one search.

  `params` are the API's own, such as `"q"`. Returns `{:error, message}` if `settings` has no
  `:api_key`, or if Brave answers with a 4xx other than 429.
  """
  @spec search(map(), map()) :: {:ok, map()} | {:error, String.t()} | no_return()
  def search(%{api_key: key}, _params) when key in [nil, ""],
    do: {:error, "Web search has no key. Whoever runs Wardrik gives it one, as brave.api_key."}

  def search(settings, params) do
    options =
      [
        json: params,
        headers: %{"x-subscription-token" => settings.api_key, "accept" => "application/json"},
        receive_timeout: @receive_timeout,
        retry: false
      ] ++
        settings.req_options

    case Req.post(settings.base_url <> @path, options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, summarized(body)}

      {:ok, %Req.Response{status: 429}} ->
        raise WardrikBrave.Unavailable, "Brave is limiting searches just now."

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        raise WardrikBrave.Unavailable, "Brave's search answered #{status}."

      {:ok, %Req.Response{status: status}} ->
        {:error, "Brave's search answered #{status}."}

      {:error, reason} ->
        raise WardrikBrave.Unavailable,
              "Brave's search didn't answer: #{Exception.message(reason)}"
    end
  end

  @doc """
  Returns `%{"results" => [...], "count" => n}`. Each result has `"url"`, `"title"`, `"snippets"`
  and, where known, `"age"`.
  """
  @spec summarized(term()) :: map()
  def summarized(%{} = body) do
    sources = Map.get(body, "sources", %{})
    results = for %{} = entry <- generic(body["grounding"]), do: result(entry, sources)
    %{"results" => results, "count" => length(results)}
  end

  def summarized(_body), do: %{"results" => [], "count" => 0}

  defp generic(%{"generic" => generic}) when is_list(generic), do: generic
  defp generic(_grounding), do: []

  defp result(entry, sources) do
    %{
      "url" => entry["url"],
      "title" => entry["title"],
      "snippets" => Map.get(entry, "snippets", []),
      "age" => age(sources, entry["url"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp age(sources, url) do
    case sources do
      %{^url => %{"age" => [readable | _rest]}} -> readable
      _unknown -> nil
    end
  end
end

defmodule WardrikBrave.Unavailable do
  @moduledoc "Raised when a search fails in a way that a retry may fix."
  defexception [:message]
end
