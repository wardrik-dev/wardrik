defmodule Tars.MixProject do
  use Mix.Project

  def project do
    [
      app: :tars,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Tars.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.21"},
      {:owl, "~> 0.13.1"},

      # Test and dev
      {:mimic, "~> 1.7", only: :test}
    ]
  end
end
