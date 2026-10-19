# Architecture policy for `mix reach.check --arch`.
#
# Core is `Wardrik.*`, with the store it keeps everything in, `WardrikStore.*`,
# and the JSON Schemas of what it says, `WardrikProtocol.*`. Each package under
# packages/ depends on it. The modules below are core's own: only core calls
# them.
[
  layers: [
    core: ["Wardrik", "Wardrik.*"],
    store: ["WardrikStore", "WardrikStore.*"],
    protocol: ["WardrikProtocol", "WardrikProtocol.*", "Mix.Tasks.WardrikProtocol.Bundle"]
  ],
  # The store and the schemas stand on their own: core reads both, and
  # neither reads core or the other.
  deps: [
    forbidden: [
      {:store, :core},
      {:store, :protocol},
      {:protocol, :core},
      {:protocol, :store}
    ]
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
      # Core takes its settings as options of `Wardrik.Core`, and reads the
      # application environment only where `Wardrik.Test` hands a suite the
      # store and host it started on.
      {["Wardrik", "Wardrik.*"],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Application.put_env",
         "Application.delete_env"
       ],
       except: ["Wardrik.Test"]}
    ]
  ],
  smells: [
    behaviour_candidate: [
      # Wardrik.Ledger, Wardrik.LLM.Client and Wardrik.Runtime are protocols,
      # and their implementations share their functions by design; the check
      # groups modules by their public functions, and does not read the
      # protocol they implement.
      ignore: [
        modules: [
          "Wardrik.Ledger",
          "Wardrik.Ledger.*",
          "Wardrik.LLM.Client",
          "Wardrik.LLM.Client.*",
          "Wardrik.Runtime",
          "Wardrik.Runtime.*"
        ]
      ]
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
