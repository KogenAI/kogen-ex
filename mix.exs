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
      {:ex_dna, "== 1.5.4", only: :dev, runtime: false},
      {:reach, "== 2.8.4", only: :dev, runtime: false},
      {:styler, "== 1.12.2", only: [:dev, :test], runtime: false},
      {:kogen_checks, path: "tools/kogen_checks", only: [:dev, :test], runtime: false}
    ]
  end

  # Kogen has no product version yet, so the build identity is the source commit, its
  # commit date and whether the tree had uncommitted changes: 0.0.0+<sha8>.<yyyymmdd>[.dirty].
  defp version do
    with {:ok, sha} <- git(["rev-parse", "--short=8", "HEAD"]),
         {:ok, date} <- git(["show", "-s", "--format=%cd", "--date=format:%Y%m%d", "HEAD"]),
         {:ok, changes} <- git(["status", "--porcelain", "--untracked-files=no"]) do
      dirty = if changes == "", do: "", else: ".dirty"
      "0.0.0+#{sha}.#{date}#{dirty}"
    else
      _unavailable -> "0.0.0+unknown"
    end
  rescue
    _error -> "0.0.0+unknown"
  end

  defp git(args) do
    case System.cmd("git", args, cd: __DIR__, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _failed -> :error
    end
  end
end
