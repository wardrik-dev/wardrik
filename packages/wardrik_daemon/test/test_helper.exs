Mimic.copy(WardrikDaemon.AgentFile)
Mimic.copy(WardrikDaemon.CLI)
Mimic.copy(Wardrik.Fleet)
Mimic.copy(Wardrik.Store)

# The tests that reach real services, which dev/services.sh starts, are
# left out where nothing answers; see Wardrik.Test.Services.
Wardrik.Test.start(
  wait: [WardrikPolicy.Meter.supervisor()],
  exclude: Wardrik.Test.Services.start()
)
