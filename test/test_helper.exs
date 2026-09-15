Mimic.copy(ReqLLM)
Mimic.copy(ReqLLM.StreamResponse)

# The first `ReqLLM.model/1` anywhere loads the model database, which measures
# at about 1.3s; every lookup after it is instant. `TarsTUI.Usage.new/1` does
# one for the model an agent is running, so left to happen lazily this lands on
# whichever `TarsTUI.AppTest` case runs first, reads as a one-second test with
# nothing slow in it, and moves to a different case on the next seed. Paying it
# here makes every reported duration the test's own.
ReqLLM.model("test:model")

ExUnit.start()
