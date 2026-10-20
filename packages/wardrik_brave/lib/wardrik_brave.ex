defmodule WardrikBrave do
  @moduledoc """
  Web search for agents, through Brave's LLM Context API, attached to the
  `Wardrik.Host` they run on, where a definition names it as `web_search`:

      host = WardrikBrave.attach(host, api_key: System.fetch_env!("BRAVE_API_KEY"))

  `WardrikBrave.WebSearch` is the tool, and says what a search answers.
  """

  @doc """
  `host` with `WardrikBrave.WebSearch` among its tools, as `web_search`,
  searching with `:api_key` for every agent the host runs. The key is held
  in the host, among its `:settings`, never in the store; without one, a
  search answers that the key is missing.
  """
  @spec attach(Wardrik.Host.t(), api_key: String.t()) :: Wardrik.Host.t()
  def attach(%Wardrik.Host{} = host, opts \\ []) do
    opts = Keyword.validate!(opts, [:api_key])

    host
    |> Wardrik.Host.register(:tools, [{"web_search", WardrikBrave.WebSearch}])
    |> Wardrik.Host.register(:settings, [{WardrikBrave.WebSearch, opts}])
  end
end
