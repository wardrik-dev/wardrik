defmodule Wardrikd.Application do
  @moduledoc """
  The daemon's tree, started once every package's application is running.

  Core's own application would start the store as it boots, before the
  applications of a store kept elsewhere, such as Postgres through
  wardrik_ecto, have started. The release's application depends on all of
  them, so starting Wardrik here starts it last.

  What runs on the fleet starts after it, so once the fleet is up, and goes
  with it: `WardrikPolicy.Supervisor` keeps the budgets, `WardrikSchedule`
  runs the schedules, `WardrikHTTP.Access` keeps what tokens grant,
  `WardrikHTTP.Workers` the tool workers' group, and `WardrikDaemon` the
  rest. `WardrikDaemon.Cluster` connects this node to
  the others before the fleet starts.

  The store, and whether tool workers' answers are the deployment's own, are
  what `config/runtime.exs` read of `config.yaml` as the node booted; see
  `WardrikDaemon.Config.boot/1`.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    http = WardrikDaemon.Config.settings(WardrikHTTP)

    children = [
      {Wardrik,
       store: WardrikDaemon.Config.settings(Wardrik.Store),
       cluster: [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]},
      WardrikPolicy.Supervisor,
      WardrikSchedule,
      WardrikHTTP.Access,
      {WardrikHTTP.Workers, trusted: Keyword.get(http, :trusted_workers, false)},
      WardrikDaemon
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Wardrikd.Supervisor)
  end
end
