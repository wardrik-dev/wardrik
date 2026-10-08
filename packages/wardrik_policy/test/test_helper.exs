Mimic.copy(WardrikPolicy.Meter)

Wardrik.Test.start(
  llm_stub: true,
  children: [WardrikPolicy.Supervisor],
  wait: [WardrikPolicy.Meter.supervisor()]
)
