[
  layers: [
    triggers: ["WardrikTriggers", "WardrikTriggers.*"]
  ],
  calls: [
    forbidden: [
      {["WardrikTriggers", "WardrikTriggers.*"],
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
