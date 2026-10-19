defmodule WardrikBrave do
  @moduledoc """
  Web search for agents, through Brave's LLM Context API, attached to the
  `Wardrik.Host` they run on, where a definition names it as `web_search`:

      host = WardrikBrave.attach(host)

  `WardrikBrave.WebSearch` is the tool, and says what a search answers and
  the key it needs.
  """

  @doc "`host` with `WardrikBrave.WebSearch` among its tools, as `web_search`. It takes no options."
  @spec attach(Wardrik.Host.t(), keyword()) :: Wardrik.Host.t()
  def attach(%Wardrik.Host{} = host, opts \\ []) do
    Keyword.validate!(opts, [])
    Wardrik.Host.register(host, :tools, [{"web_search", WardrikBrave.WebSearch}])
  end
end
