# Architecture policy for `mix reach.check --arch`.
#
# WardrikCore is one layer. Its public surface is `WardrikCore` and the
# modules under `Wardrik` that tools and extensions are written against,
# such as `Wardrik.Tool`, `Wardrik.Capability` and `Wardrik.Context`; the
# modules below are its own.
[
  layers: [
    core: [
      "WardrikCore",
      "WardrikCore.*",
      "Wardrik.Capability",
      "Wardrik.Context",
      "Wardrik.Credentials",
      "Wardrik.Credentials.*",
      "Wardrik.Format",
      "Wardrik.Keys",
      "Wardrik.Keys.*",
      "Wardrik.Middleware",
      "Wardrik.Principal",
      "Wardrik.Resume",
      "Wardrik.Tool",
      "Wardrik.ToolCall"
    ]
  ],
  boundaries: [
    internal: [
      "WardrikCore.Agent.State",
      "WardrikCore.Turn",
      "WardrikCore.ToolRunner"
    ],
    internal_callers: [
      {"WardrikCore.Agent.State", ["WardrikCore", "WardrikCore.*"]},
      {"WardrikCore.Turn", ["WardrikCore", "WardrikCore.*"]},
      {"WardrikCore.ToolRunner", ["WardrikCore", "WardrikCore.*"]}
    ]
  ],
  calls: [
    forbidden: [
      # A library takes its settings as options, never from the application
      # environment.
      {["WardrikCore", "WardrikCore.*"],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Application.put_env",
         "Application.delete_env"
       ]}
    ]
  ],
  checks: [
    layer_coverage: [require_all_modules: true, forbid_multiple_matches: true]
  ]
]
