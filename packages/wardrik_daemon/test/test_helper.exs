Mimic.copy(WardrikDaemon.AgentFile)
Mimic.copy(WardrikDaemon.CLI)
Mimic.copy(Wardrik.Fleet)
Mimic.copy(Wardrik.Store)

# The tests that reach real services, which dev/services.sh starts, are
# left out where nothing answers; see WardrikEcto.Test.Services.
Wardrik.Test.start(
  children: [WardrikPolicy.Supervisor, WardrikSchedule, WardrikHTTP.Access, WardrikHTTP.Workers],
  wait: [WardrikPolicy.Meter.supervisor(), WardrikSchedule.supervisor()],
  exclude: WardrikEcto.Test.Services.start()
)
