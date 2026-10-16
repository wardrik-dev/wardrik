Mimic.copy(WardrikPolicy.Meter)

Wardrik.Test.start(
  llm_stub: true,
  children:
    Wardrik.Test.children() ++
      [{WardrikPolicy.Supervisor, store: Wardrik.Test.store()}],
  wait: [WardrikPolicy.Meter.supervisor()]
)
