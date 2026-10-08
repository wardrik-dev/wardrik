defmodule Wardrik.Fleet.Supervisor do
  @moduledoc """
  Starts the substrate the fleet runs on.

  Two children, in order:

    * `Wardrik.Store` - the durable store agent state is written to, as the
      deployment configured it.
    * `DurableServer.Supervisor` - keyed processes over that store, named
      `Wardrik.Fleet`. It starts a `Group` instance under the same name, which is
      the registry `Wardrik.Fleet` reads.

  ## Options

    * `:store` - the store's adapter and its options, as `Wardrik` takes them;
      the options belong to the adapter, see `Wardrik.Store.EKV`
    * `:log` - passed to `Group`, `false` by default

  `Wardrik` starts it with its `:store` and its `:fleet`.

  ## Joining other nodes

  The fleet writes to the store as it starts, and a store counting a quorum
  over several nodes can write only once enough of them are connected. What
  connects them is `Wardrik`'s `:cluster`, which it starts before this and
  keeps running beside it:

      {Wardrik, cluster: [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]}
  """

  use Supervisor

  alias Wardrik.Store

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, [])

    children = [
      Store.child_spec(store),
      {DurableServer.Supervisor,
       [
         name: Wardrik.Fleet,
         prefix: Wardrik.Fleet.prefix(),
         backend: Store.durable_backend(store),
         group: [log: Keyword.get(opts, :log, false)]
       ] ++ Store.durable_shutdown()}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
