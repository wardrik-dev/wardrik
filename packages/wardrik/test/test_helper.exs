Mimic.copy(WardrikEcto.Migration)
Mimic.copy(Ecto.Adapters.SQL)
Mimic.copy(WardrikPolicy.Meter)
Mimic.copy(ReqLLM)

# One runtime for the suite, with the budgets' meters and the triggers beside
# it. A feed a trigger watches is read through Req.Test. The tests that reach
# real services, which dev/services.sh starts, are left out where nothing
# answers; see WardrikEcto.Test.Services and WardrikS3.Test.Services.
Wardrik.Test.start(
  children:
    Wardrik.Test.children() ++
      [
        {WardrikPolicy.Supervisor, store: Wardrik.Test.store()},
        {WardrikTrigger,
         store: Wardrik.Test.store(),
         host: Wardrik.Test.host(),
         settings: %{
           WardrikTrigger.Feed => [
             req_options: [plug: {Req.Test, WardrikTrigger.Feed}, retry: false]
           ]
         }}
      ],
  wait: [WardrikPolicy.Meter.supervisor(), WardrikTrigger.supervisor()],
  exclude: WardrikEcto.Test.Services.start() ++ WardrikS3.Test.Services.start()
)
