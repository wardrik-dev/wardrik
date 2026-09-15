Mimic.copy(ReqLLM)
Mimic.copy(ReqLLM.StreamResponse)

# The first `ReqLLM.model/1` anywhere loads the model database, which measures
# at about 1.3s; every lookup after it is instant. `TarsTUI.Usage.new/1` does
# one for the model an agent is running, so left to happen lazily this lands on
# whichever `TarsTUI.AppTest` case runs first, reads as a one-second test with
# nothing slow in it, and moves to a different case on the next seed. Paying it
# here makes every reported duration the test's own.
ReqLLM.model("test:model")

# The fleet writes to a real store, so the suite gets its own and removes it
# afterwards. Started here rather than in config so the directory is unique per
# run and two suites can run side by side.
data_dir =
  Path.join([
    System.tmp_dir!(),
    "tars-test",
    "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  ])

Application.put_env(:tars, Tars.Fleet, data_dir: data_dir)
{:ok, _apps} = Application.ensure_all_started(:tars)
:ok = DurableServer.Supervisor.wait_until_ready(Tars.Fleet, timeout: 10_000)

ExUnit.after_suite(fn _results ->
  Supervisor.stop(Tars.Fleet.Supervisor)
  File.rm_rf(data_dir)
end)

ExUnit.start()
