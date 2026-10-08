# Architecture policy for `mix reach.check --arch`.
#
# WardrikS3 depends on wardrik_store alone, whose behaviour it implements.
[
  layers: [
    s3: ["WardrikS3", "WardrikS3.*"]
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true
    ]
  ]
]
