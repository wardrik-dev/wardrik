defmodule WardrikDaemon.Application do
  @moduledoc """
  The release's tree, started once every package's application is running.

  The store starts here, once the applications of a store kept elsewhere,
  such as Postgres through wardrik_ecto, have started: this application
  depends on all of them, so it starts last.

  What `config/runtime.exs` read of `config.yaml` as the node booted, the
  store, the cluster and the HTTP API's settings, and what the release's
  own configuration says of each module, and the channel adapters, trigger
  sources and webhook verifiers the loaded applications register, are read
  here once, and handed down: the store `storage` names starts first; `WardrikDaemon.Boot` holds it
  and the cluster's settings, for the commands that reach the node over rpc
  while it waits; `WardrikDaemon.Cluster` connects this node to the others,
  and `WardrikDaemon.Cluster.Quorum` waits for enough of them; then
  `WardrikDaemon.Tree` reads the rest of `config.yaml`, builds the host and
  starts core and the daemon. See `WardrikDaemon.Config.boot/1`.

  `DurableServer`, which runs the fleet, the triggers and the budgets, logs
  its warnings and errors alone: at `info` it writes a line every few seconds
  for each of its supervisors, which buries the daemon's own.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    :ok = Logger.put_application_level(:durable_server, :warning)
    base = Application.get_all_env(:wardrik_daemon)
    store = WardrikStore.new(Keyword.get(base, WardrikStore, []))
    cluster = Keyword.get(base, WardrikDaemon.Cluster, [])

    children = [
      {WardrikStore, store},
      {WardrikDaemon.Boot, store: store, cluster: cluster},
      {WardrikDaemon.Cluster, cluster},
      {WardrikDaemon.Cluster.Quorum, store: store, cluster: cluster},
      {WardrikDaemon.Tree,
       store: store,
       base: base,
       adapters: WardrikChannel.discover(),
       triggers: WardrikTrigger.Offered.discover()}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: WardrikDaemon.Supervisor)
  end
end
