# Architecture policy for `mix reach.check --arch`.
#
# WardrikEcto depends on wardrik_store alone, whose behaviour it implements.
[
  layers: [
    ecto: ["WardrikEcto", "WardrikEcto.*"]
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true
    ]
  ]
]
