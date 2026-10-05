defmodule KogenChecks.MixProject do
  use Mix.Project

  def project do
    [
      app: :kogen_checks,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: deps(),
      elixirc_paths: ["lib"],
      test_ignore_filters: [~r"/support/"]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [{:credo, "== 1.7.19"}]
  end
end
