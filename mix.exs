defmodule Kogen.MixProject do
  use Mix.Project

  def project do
    [
      app: :kogen,
      version: version(),
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:boundary] ++ Mix.compilers(),
      elixirc_options: compiler_options(Mix.env()),
      boundary: [
        default: [type: :strict, check: [aliases: true, apps: [{:mix, :runtime}]]]
      ],
      test_ignore_filters: [~r"/support/"],
      dialyzer: [
        plt_local_path: System.get_env("KOGEN_PLT_DIR", Path.expand("~/.kogen/plt")),
        plt_core_path: System.get_env("KOGEN_PLT_DIR", Path.expand("~/.kogen/plt")),
        plt_add_apps: [:mix, :ex_unit]
      ],
      escript: [main_module: Kogen.Kernel.CLI, name: "kogen"],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp compiler_options(:dev), do: [tracers: [KogenChecks.CapabilityGuard]]

  defp compiler_options(_env), do: []

  defp deps do
    [
      {:boundary, "== 0.11.0", runtime: false},
      {:credo, "== 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "== 1.4.8", only: [:dev, :test], runtime: false},
      {:styler, "== 1.12.2", only: [:dev, :test], runtime: false},
      {:kogen_checks, path: "tools/kogen_checks", only: [:dev, :test], runtime: false}
    ]
  end

  defp version do
    case System.cmd("git", ["describe", "--always", "--dirty"],
           cd: __DIR__,
           stderr_to_stdout: true
         ) do
      {description, 0} -> "0.0.0+#{String.trim(description)}"
      _unavailable -> "0.0.0+unknown"
    end
  rescue
    _error -> "0.0.0+unknown"
  end
end
