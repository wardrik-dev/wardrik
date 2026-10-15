Wardrik.Test.start(
  children: [{WardrikTrigger, store: Wardrik.Test.store()}],
  wait: [WardrikTrigger.supervisor()]
)
