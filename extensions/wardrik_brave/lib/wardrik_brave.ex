defmodule WardrikBrave do
  @moduledoc """
  Web search for agents, through Brave's LLM Context API.

  Application integration fragment. Start the required processes before calling these functions.
  See the [package README](https://github.com/wardrik-dev/wardrik/tree/main/extensions/wardrik_brave#readme) for complete setup.

      children = [{WardrikBrave, name: MyApp.Brave, api_key: System.fetch_env!("BRAVE_API_KEY")}]

      WardrikCore.start_agent(
        agent_id: "agt_triage",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikBrave, brave: MyApp.Brave}]
      )

    * Each search uses `BRAVE_API_KEY` from the agent's `WardrikCore.Keys` first, then `:api_key`.
    * Without a process, give the options inline: `{WardrikBrave, []}`.
    * The tool is `open_world`: anyone could have written the pages it finds.

  ## Options

  Given to `start_link/1`, or inline in place of `:brave`:

    * `:api_key` - the key to use when the agent's keys hold none.
    * `:req_options` - merged into every request. `[]` unless set.
    * `:base_url` - `"https://api.search.brave.com"` unless set.
    * `:key_help` - how to give it a key, in your app's words, as `"Set BRAVE_API_KEY."`. While
      there's no key, the tool's description and its error say it.
  """

  @behaviour WardrikCore.Capability

  use GenServer

  @settings [
    api_key: nil,
    req_options: [],
    base_url: "https://api.search.brave.com",
    key_help: nil
  ]

  @doc "Starts a process holding the search options under `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:name | @settings])

    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl WardrikCore.Capability
  def tools(context, opts), do: [WardrikBrave.WebSearch.tool(source(opts), context)]

  defp source(opts) do
    case Keyword.fetch(opts, :brave) do
      {:ok, brave} ->
        brave

      :error ->
        opts
        |> Keyword.validate!(@settings)
        |> Map.new()
    end
  end

  @doc "Returns the settings started under `brave`, or `brave` itself if it's a map."
  @spec settings(atom() | map()) :: map()
  def settings(%{} = settings), do: settings

  def settings(brave) do
    [{:settings, settings}] = :ets.lookup(brave, :settings)
    settings
  rescue
    ArgumentError ->
      reraise ArgumentError,
              "#{inspect(brave)} isn't started. Add {WardrikBrave, name: #{inspect(brave)}, api_key: key} to your supervision tree.",
              __STACKTRACE__
  end

  @impl GenServer
  def init(opts) do
    table =
      :ets.new(Keyword.fetch!(opts, :name), [:named_table, :protected, read_concurrency: true])

    true = :ets.insert(table, {:settings, Map.new(Keyword.delete(opts, :name))})
    {:ok, table}
  end
end
