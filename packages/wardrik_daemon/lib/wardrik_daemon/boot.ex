defmodule WardrikDaemon.Boot do
  @moduledoc """
  Holds what a release booted with, the store and the cluster's settings,
  for a `wardrik` command that reaches the node over rpc while it waits for
  its cluster, before the daemon's tree has read `config.yaml`: it says how
  many nodes the node waits for. The release starts it after the store.
  """

  use GenServer

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts it, holding `:store` and `:cluster`."
  @spec start_link(store: WardrikStore.t(), cluster: WardrikDaemon.Cluster.settings()) ::
          GenServer.on_start()
  def start_link(opts) do
    held = Map.new(Keyword.validate!(opts, [:store, cluster: []]))
    GenServer.start_link(__MODULE__, held, name: __MODULE__)
  end

  @doc "The store the release booted with."
  @spec store() :: WardrikStore.t()
  def store, do: GenServer.call(__MODULE__, :store)

  @doc "The cluster's settings the release booted with."
  @spec cluster() :: WardrikDaemon.Cluster.settings()
  def cluster, do: GenServer.call(__MODULE__, :cluster)

  @impl GenServer
  def init(held), do: {:ok, held}

  @impl GenServer
  def handle_call(key, _from, held), do: {:reply, Map.fetch!(held, key), held}
end
