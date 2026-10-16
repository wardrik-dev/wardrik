Wardrik.Test.start(
  children:
    Wardrik.Test.children() ++
      [{WardrikTrigger, store: Wardrik.Test.store()}],
  wait: [WardrikTrigger.supervisor()]
)
