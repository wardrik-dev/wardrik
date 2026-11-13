defmodule WardrikDaemon.Rest do
  @moduledoc """
  Gives agents the HTTP APIs `config.yaml`'s `rest` names, each as a tool group of the same name.

      tools: [ga4]

    * Each API's description is read as the daemon starts. One that doesn't read is logged, and
      read again each minute. Until it reads, it offers no tools.
    * A description's URL is checked as any URL the daemon reaches is. See `WardrikDaemon.Egress`.
    * The agent's org must use the API. See `WardrikDaemon.Config.Orgs`.

  See `WardrikDaemon.Config.Rest` and `WardrikRest`.
  """

  use GenServer

  @behaviour WardrikCore.Capability

  require Logger

  alias WardrikDaemon.Config
  alias WardrikDaemon.Config.Orgs
  alias WardrikDaemon.Config.Rest, as: Entry
  alias WardrikDaemon.Owners
  alias WardrikRest.Discovery

  @retry :timer.minutes(1)

  @doc "Returns the name the APIs are held under for `wardrik`, as `MyWardrik.Rest`."
  @spec name(atom()) :: atom()
  def name(wardrik), do: Module.concat(wardrik, Rest)

  @doc "Returns each API by name, as Wardrik's `:capabilities` option takes them."
  @spec capabilities(atom(), Wardrik.Store.t(), Config.t()) :: [{String.t(), {module(), map()}}]
  def capabilities(wardrik, store, config) do
    for {name, _entry} <- config.rest,
        do: {name, {__MODULE__, %{rest: name(wardrik), store: store, config: config, name: name}}}
  end

  @impl WardrikCore.Capability
  def tools(context, %{rest: rest, store: store, config: config, name: name}) do
    org = Owners.org_of(store, {:agent, context.agent_id})

    with true <- Orgs.serves?(config, kind: :rest, name: name, org: org),
         {:ok, api} <- GenServer.call(rest, {:api, name}) do
      WardrikRest.tools(context, apis: [api])
    else
      _none -> []
    end
  end

  @doc """
  Starts the process that reads and holds the APIs.

    * `:name` - what it's started under. See `name/1`.
    * `:apis` - `config.yaml`'s `rest`, as `WardrikDaemon.Config.Rest` reads it.
    * `:dir` - where a description's path is from.
    * `:egress` - checks each URL. See `WardrikDaemon.Egress`.
    * `:req_options` - merged into every request. `[]` unless set.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:name, :apis, :dir, :egress, req_options: []])
    GenServer.start_link(__MODULE__, Map.new(opts), name: opts[:name])
  end

  @impl GenServer
  def init(settings), do: {:ok, %{settings: settings, apis: %{}}, {:continue, :read}}

  @impl GenServer
  def handle_continue(:read, state), do: {:noreply, read(state)}

  @impl GenServer
  def handle_info(:read, state), do: {:noreply, read(state)}

  @impl GenServer
  def handle_call({:api, name}, _from, state), do: {:reply, Map.fetch(state.apis, name), state}

  defp read(%{settings: settings, apis: apis} = state) do
    read =
      Enum.reduce(settings.apis, apis, fn {name, entry}, read ->
        if Map.has_key?(read, name), do: read, else: loaded(read, settings, {name, entry})
      end)

    if map_size(read) < length(settings.apis), do: Process.send_after(self(), :read, @retry)
    %{state | apis: read}
  end

  defp loaded(read, settings, {name, %Entry{} = entry}) do
    opts =
      [name: name, egress: settings.egress, req_options: settings.req_options] ++ entry.options

    with {:ok, discovery} <- described(settings, entry.discovery),
         {:ok, api} <- WardrikRest.API.load(discovery, opts) do
      Map.put(read, name, api)
    else
      {:error, reason} ->
        Logger.warning("rest.#{name} isn't read: #{reason} It's read again in a minute.")
        read
    end
  end

  defp described(settings, location) do
    if URI.parse(location).scheme in ["http", "https"],
      do: fetched(settings, location),
      else: file(settings, location)
  end

  defp fetched(settings, url) do
    with :ok <- settings.egress.(url),
         do: {:ok, {Discovery, url: url, req_options: settings.req_options}}
  end

  defp file(settings, path) do
    full = Path.expand(path, settings.dir)

    with {:ok, text} <- File.read(full),
         {:ok, document} <- JSON.decode(text) do
      {:ok, {Discovery, document: document}}
    else
      {:error, reason} -> {:error, "#{full} doesn't read: #{inspect(reason)}."}
    end
  end
end
