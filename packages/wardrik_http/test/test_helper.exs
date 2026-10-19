# A holder that outlives its revocation is killed after a twentieth of a
# second rather than a second. The definitions agents are defined with bring
# their triggers to what they list, so the triggers run.
Wardrik.Test.start(
  children:
    Wardrik.Test.children() ++
      [
        {WardrikTrigger, store: Wardrik.Test.store(), host: Wardrik.Test.host()},
        {WardrikHTTP.Access, store: Wardrik.Test.store(), grace: 50},
        WardrikHTTP.Workers
      ],
  wait: [WardrikTrigger.supervisor()]
)
