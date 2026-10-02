Mimic.copy(ReqLLM)
Mimic.copy(ReqLLM.StreamResponse)
Mimic.copy(WardrikPolicy.Meter)
Mimic.copy(WardrikDaemon.AgentFile)
Mimic.copy(Wardrik.Store)
Mimic.copy(Ecto.Adapters.SQL)
Mimic.copy(Wardrik.Store.Memory)
Mimic.copy(Wardrik.Fleet)
Mimic.copy(WardrikDaemon.CLI)

# `Wardrik.LLM.Catalog` loads the model database in the background as the
# application starts, which takes about 1.3s. A lookup made before it finishes
# waits for it, so left alone that wait lands on whichever test first prices a
# request and moves to a different case on the next seed. Waiting here makes
# every reported duration the test's own.
ReqLLM.model("test:model")

:ok = DurableServer.Supervisor.wait_until_ready(Wardrik.Fleet, timeout: 10_000)
:ok = DurableServer.Supervisor.wait_until_ready(Wardrik.Schedule.supervisor(), timeout: 10_000)
:ok = DurableServer.Supervisor.wait_until_ready(WardrikPolicy.Meter.supervisor(), timeout: 10_000)

# The store configured for this run, see config/test.exs, is removed with it.
ExUnit.after_suite(fn _results ->
  Supervisor.stop(Wardrik.Fleet.Supervisor)
  File.rm_rf(Application.fetch_env!(:wardrik, Wardrik.Store)[:data_dir])
  # Let the OS monitor close its native helper before the VM tears down ports.
  Application.stop(:os_mon)
end)

# An assert_receive returns as soon as its message arrives, so a generous
# timeout costs a passing test nothing and keeps a suite running 64 cases at
# once from failing one whose message was merely late. refute_receive keeps
# its default, since it always waits the whole of it.
# The :postgres and :s3 tests reach real services, which dev/services.sh
# starts; see Wardrik.Test.Services.
excluded = Wardrik.Test.Services.start()

ExUnit.start(capture_log: true, assert_receive_timeout: 1_000, exclude: excluded)
