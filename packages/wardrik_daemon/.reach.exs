[
  layers: [
    daemon: ["WardrikDaemon", "WardrikDaemon.*"],
    mix: ["Mix.Tasks.*"]
  ],
  calls: [
    forbidden: [
      {["WardrikDaemon", "WardrikDaemon.*"],
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
