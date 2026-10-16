defmodule Wardrik.Fleet.Supervisor do
  @moduledoc """
  Starts the substrate the fleet runs on: a `DurableServer.Supervisor` of
  keyed processes over the host's store, named `Wardrik.Fleet`. It starts a
  `Group` instance under the same name, which is the registry
  `Wardrik.Fleet` reads.

  ## Options

    * `:host` - the `Wardrik.Host` whose store agents are written to, and
      which every agent is handed as it starts, wakes, or restarts on another
      node, as `DurableServer`'s `:init_info`. Required. It is never written
      to the store
    * `:log` - passed to `Group`, `false` by default

  `Wardrik.Core` starts it with its `:fleet` and its `:host`.

  ## Joining other nodes

  The fleet writes to the store as it starts, and a store counting a quorum
  over several nodes can write only once enough of them are connected. What
  connects them is `Wardrik.Core`'s `:cluster`, which it starts before this and
  keeps running beside it:

      {Wardrik.Core, cluster: [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]}
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)

    children = [
      {DurableServer.Supervisor,
       [
         name: Wardrik.Fleet,
         prefix: Wardrik.Fleet.prefix(),
         backend: host |> Wardrik.Host.store() |> WardrikStore.durable_backend(),
         group: [log: Keyword.get(opts, :log, false)],
         init_info: %{host: host}
       ] ++ WardrikStore.durable_shutdown()}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
