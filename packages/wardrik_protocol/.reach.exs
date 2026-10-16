# Architecture policy for `mix reach.check --arch`.
#
# WardrikProtocol depends on no other package here: core, the HTTP API and the
# SDKs all read it.
[
  layers: [
    protocol: ["WardrikProtocol", "WardrikProtocol.*"],
    bundle: "Mix.Tasks.WardrikProtocol.Bundle"
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true
    ]
  ]
]
