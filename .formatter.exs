# Used by "mix format"
[
  plugins: [Breeze.HTMLFormatter],
  import_deps: [:breeze, :plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", ".credo/**/*.ex"]
]
