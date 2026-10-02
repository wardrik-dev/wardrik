# The model catalog loads as the application starts; waiting for it here
# keeps its load out of whichever test first prices a request.
ReqLLM.model("test:model")

:ok = DurableServer.Supervisor.wait_until_ready(Wardrik.Fleet, timeout: 10_000)
:ok = DurableServer.Supervisor.wait_until_ready(Wardrik.Schedule.supervisor(), timeout: 10_000)

# The tests that reach real services, which dev/services.sh starts, are
# left out where nothing answers; see Wardrik.Test.Services.
excluded = Wardrik.Test.Services.start()

ExUnit.start(capture_log: true, assert_receive_timeout: 1_000, exclude: excluded)
