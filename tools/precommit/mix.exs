defmodule WardrikPrecommit.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik_precommit,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  # :tools is :cover, which crap reads the exported coverage with.
  def application, do: [extra_applications: [:logger, :tools]]

  # The tools every package's precommit runs. A package depends on this alone,
  # `only: [:dev, :test]`, and has them all.
  defp deps do
    [
      {:credo, "~> 1.7", runtime: false},
      {:ex_slop, "~> 0.4", runtime: false},
      {:ex_dna, "~> 1.5", runtime: false},
      {:ex_crap, "~> 0.1.0", runtime: false},
      {:reach, "~> 2.8", runtime: false},
      {:dialyxir, "~> 1.4", runtime: false}
    ]
  end
end
