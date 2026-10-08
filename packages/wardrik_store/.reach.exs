# Architecture policy for `mix reach.check --arch`.
#
# WardrikStore depends on no other package here: core and the packages that
# keep records call it, and adapters implement it.
[
  layers: [
    store: ["WardrikStore", "WardrikStore.*"]
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true
    ]
  ]
]
