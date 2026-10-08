defmodule Wardrik.Fleet.Supervisor do
  @moduledoc """
  Starts the substrate the fleet runs on.

  Two children, in order:

    * `Wardrik.Store` - the durable store agent state is written to, as the
      deployment configured it.
    * `DurableServer.Supervisor` - keyed processes over that store, named
      `Wardrik.Fleet`. It starts a `Group` instance under the same name, which is
      the registry `Wardrik.Fleet` reads.

  ## Configuration

      config :wardrik, Wardrik.Store, adapter: Wardrik.Store.EKV, data_dir: "/var/lib/wardrik"
      config :wardrik, Wardrik.Fleet, log: false

  The store's options belong to its adapter; see `Wardrik.Store.EKV`. `:log` is
  passed to `Group`.

  ## Joining other nodes

  The fleet writes to the store as it starts, and a store counting a quorum
  over several nodes can write only once enough of them are connected. What
  connects them is named in `:cluster`, which the application starts before
  this and keeps running beside it:

      config :wardrik, :cluster, [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]
  """

  use Supervisor

  alias Wardrik.Store

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      Store.child_spec(),
      {DurableServer.Supervisor,
       [
         name: Wardrik.Fleet,
         prefix: Wardrik.Fleet.prefix(),
         backend: Store.durable_backend(),
         group: [log: Keyword.get(opts, :log, false)]
       ] ++ Store.durable_shutdown()}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
