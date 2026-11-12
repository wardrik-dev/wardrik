[
  layers: [
    protocol: ["WardrikProtocol", "WardrikProtocol.*"],
    surface: ["Wardrik.*"]
  ],
  calls: [
    forbidden: [
      {["WardrikProtocol", "WardrikProtocol.*", "Wardrik.*"],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Application.put_env",
         "Application.delete_env"
       ]}
    ]
  ],
  smells: [
    ignore: [modules: ["Wardrik.Operations.Functions"]]
  ],
  checks: [
    layer_coverage: [require_all_modules: true, forbid_multiple_matches: true]
  ]
]
