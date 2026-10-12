# Architecture policy for `mix reach.check --arch`.
#
# Core is `Wardrik.*`, and each package under packages/ depends on it. The
# modules below are core's own: only core calls them.
[
  layers: [
    core: ["Wardrik", "Wardrik.*"]
  ],
  boundaries: [
    internal: [
      "Wardrik.Agent.State",
      "Wardrik.Agent.State.*",
      "Wardrik.LLM.Turn",
      "Wardrik.LLM.Turn.*",
      "Wardrik.LLM.ToolRunner",
      "Wardrik.LLM.Catalog",
      "Wardrik.Fleet.Supervisor",
      "Wardrik.Event.Source",
      "Wardrik.Trace"
    ],
    internal_callers: [
      {"Wardrik.Agent.State", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Agent.State.*", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.LLM.Turn", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.LLM.Turn.*", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.LLM.ToolRunner", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.LLM.Catalog", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Fleet.Supervisor", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Event.Source", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Trace", ["Wardrik", "Wardrik.*"]}
    ]
  ],
  calls: [
    forbidden: [
      # Core takes its settings as options of `Wardrik`, and reads the
      # application environment only where its application starts it.
      {["Wardrik", "Wardrik.*"],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Application.put_env",
         "Application.delete_env"
       ],
       except: ["Wardrik.Application"]}
    ]
  ],
  smells: [
    behaviour_candidate: [
      # Each operation implements Wardrik.AgentOperation and one of
      # Wardrik.Query or Wardrik.Command; the check groups modules by their
      # public functions, and does not read the behaviours they declare.
      ignore: [modules: ["Wardrik.Operations.*"]]
    ]
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true,
      ignore: ["Wardrik.Test.*"]
    ]
  ]
]
