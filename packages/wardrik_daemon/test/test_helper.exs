# `mix test --no-start` starts no application: not this one, the release's
# tree, and not Logger again on the suite's configuration, as starting one
# does. Logger and what the daemon depends on start here, and the trees the
# suite needs below.
:ok = Application.stop(:logger)
{:ok, _started} = Application.ensure_all_started(Application.spec(:wardrik_daemon, :applications))

Mimic.copy(WardrikDaemon.AgentFile)
Mimic.copy(WardrikDaemon.CLI)
Mimic.copy(WardrikDaemon)
Mimic.copy(WardrikDaemon.Host)
Mimic.copy(WardrikDaemon.Boot)
Mimic.copy(Wardrik.Fleet)
Mimic.copy(WardrikStore)

# The tests that reach real services, which dev/services.sh starts, are
# left out where nothing answers; see WardrikEcto.Test.Services.
# The suite's fleet runs on the host a daemon builds from the suite's own
# settings, its model calls answered by the suite's test model and the test
# runtime beside the model's, held where a command run over rpc finds it, as
# the daemon's tree holds it; see WardrikDaemon.Test.Host.
store = Wardrik.Test.store()

config =
  WardrikDaemon.Config.new(
    config_dir: System.tmp_dir!(),
    sections: Application.get_all_env(:wardrik_daemon)
  )

host = %{
  WardrikDaemon.host(config, store: store)
  | llm: Wardrik.Test.llm(),
    runtimes: Wardrik.Test.runtimes()
}

Application.put_env(:wardrik_daemon, WardrikDaemon.Test.Host, {host, config})

Wardrik.Test.start(
  children: [
    {WardrikStore, store},
    {WardrikDaemon.Boot,
     store: store, cluster: WardrikDaemon.Config.section(config, WardrikDaemon.Cluster)},
    {WardrikDaemon.Host, host: host, config: config},
    {Wardrik.Test.LLM, name: Wardrik.Test.llm().script},
    {Wardrik.Core, host: host},
    {WardrikPolicy.Supervisor, store: store},
    {WardrikTrigger, store: store, host: host},
    {WardrikHTTP.Access, store: store},
    WardrikHTTP.Workers
  ],
  wait: [WardrikPolicy.Meter.supervisor(), WardrikTrigger.supervisor()],
  exclude: WardrikEcto.Test.Services.start()
)
