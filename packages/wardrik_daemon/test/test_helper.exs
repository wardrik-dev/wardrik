Mimic.copy(WardrikDaemon.AgentFile)
Mimic.copy(WardrikDaemon.CLI)
Mimic.copy(Wardrik.Fleet)
Mimic.copy(Wardrik.Store)

# The model catalog loads as the application starts; waiting for it here
# keeps its load out of whichever test first prices a request.
ReqLLM.model("test:model")

:ok = DurableServer.Supervisor.wait_until_ready(Wardrik.Fleet, timeout: 10_000)
:ok = DurableServer.Supervisor.wait_until_ready(Wardrik.Schedule.supervisor(), timeout: 10_000)
:ok = DurableServer.Supervisor.wait_until_ready(WardrikPolicy.Meter.supervisor(), timeout: 10_000)

# The store configured for this run, see config/test.exs, is removed with it.
ExUnit.after_suite(fn _results ->
  Supervisor.stop(Wardrik.Fleet.Supervisor)
  File.rm_rf(Application.fetch_env!(:wardrik, Wardrik.Store)[:data_dir])
  Application.stop(:os_mon)
end)

# The tests that reach real services, which dev/services.sh starts, are
# left out where nothing answers; see Wardrik.Test.Services.
excluded = Wardrik.Test.Services.start()

ExUnit.start(capture_log: true, assert_receive_timeout: 1_000, exclude: excluded)
