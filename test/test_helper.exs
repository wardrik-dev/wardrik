Mimic.copy(ReqLLM)
Mimic.copy(ReqLLM.StreamResponse)

# `Tars.LLM.Catalog` loads the model database in the background as the
# application starts, which takes about 1.3s. A lookup made before it finishes
# waits for it, so left alone that wait lands on whichever test first prices a
# request and moves to a different case on the next seed. Waiting here makes
# every reported duration the test's own.
ReqLLM.model("test:model")

:ok = DurableServer.Supervisor.wait_until_ready(Tars.Fleet, timeout: 10_000)

# The store configured for this run, see config/test.exs, is removed with it.
ExUnit.after_suite(fn _results ->
  Supervisor.stop(Tars.Fleet.Supervisor)
  File.rm_rf(Application.fetch_env!(:tars, Tars.Fleet)[:data_dir])
end)

ExUnit.start()
