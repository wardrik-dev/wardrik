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
  the others before the fleet starts, and `WardrikDaemon.Agents` is where
  every surface's definitions go.

  The store, and whether tool workers' answers are the deployment's own, are
  what `config/runtime.exs` read of `config.yaml` as the node booted; see
  `WardrikDaemon.Config.boot/1`.

  `DurableServer`, which runs the fleet, the schedules and the budgets, logs
  its warnings and errors alone: at `info` it writes a line every few seconds
  for each of its supervisors, which buries the daemon's own.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    :ok = Logger.put_application_level(:durable_server, :warning)
    http = WardrikDaemon.Config.settings(WardrikHTTP)

    children = [
      {Wardrik,
       store: WardrikDaemon.Config.settings(WardrikStore),
       cluster: [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum],
       definitions: WardrikDaemon.Agents,
       fleet: [definition: {WardrikDaemon.Agents, :current, []}]},
      WardrikPolicy.Supervisor,
      WardrikSchedule,
      WardrikHTTP.Access,
      {WardrikHTTP.Workers, trusted: Keyword.get(http, :trusted_workers, false)},
      WardrikDaemon
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Wardrikd.Supervisor)
  end
end
