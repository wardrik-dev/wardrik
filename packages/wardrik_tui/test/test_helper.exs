Mimic.copy(Wardrik.Fleet)
Mimic.copy(WardrikConsole.Nodes)

# An agent a session spawns is defined from the defaults, whose definition
# brings its triggers to what it lists, so the triggers run.
Wardrik.Test.start(
  children:
    Wardrik.Test.children() ++
      [{WardrikTrigger, store: Wardrik.Test.store(), host: Wardrik.Test.host()}],
  wait: [WardrikTrigger.supervisor()]
)
