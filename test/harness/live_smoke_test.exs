defmodule Kogen.Harness.LiveSmokeTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ProviderError
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Provider.ChatGPT
  alias Kogen.Testkit.BenchmarkAuth

  @tag :live
  test "gpt-6-luna low adds a function to a temporary mini repo", %{tmp_dir: tmp_dir} do
    if live_selected?() do
      run_live(tmp_dir)
    else
      IO.puts(
        "Live Harness smoke is opt-in; run mix test --only live test/harness/live_smoke_test.exs."
      )

      assert true
    end
  end

  defp run_live(tmp_dir) do
    workdir = Kogen.Testkit.Git.create!(Path.join(tmp_dir, "mini"))
    File.mkdir_p!(Path.join(workdir, "lib"))
    source_path = Path.join(workdir, "lib/mini.ex")
    File.write!(source_path, "defmodule Mini do\nend\n")

    case BenchmarkAuth.config() do
      {:ok, provider_config} ->
        live_develop(tmp_dir, workdir, source_path, provider_config)

      {:error, :benchmark_auth_unavailable} ->
        IO.puts("Live Harness smoke skipped: set KOGEN_AUTH_PATH in the benchmark/CI job.")
        assert true

      {:error, %ProviderError{class: :login}} ->
        IO.puts("Live Harness smoke skipped: benchmark credentials are unavailable or expired.")
        assert true
    end
  end

  defp live_develop(tmp_dir, workdir, source_path, provider_config) do
    check = %CheckSpec{
      name: "greet-function",
      argv: ["sh", "-c", "grep -q 'def greet' lib/mini.ex"],
      timeout_ms: 5_000
    }

    opts = live_options(tmp_dir, workdir, provider_config, check)
    intent = "Add a function named greet/0 to lib/mini.ex that returns :hello."
    assert {:ok, result} = Harness.develop(opts, intent, nil, nil)
    source = File.read!(source_path)

    IO.puts(
      "LIVE HARNESS OUTPUT: outcome=#{result.outcome} turns=#{result.turns} gate=#{inspect(result.gate.status)} source=#{inspect(source)}"
    )

    assert result.outcome == :done
    assert source =~ "def greet"
    assert source =~ ":hello"
  end

  defp live_options(tmp_dir, workdir, provider_config, check) do
    %Opts{
      workdir: workdir,
      run_dir: Path.join(tmp_dir, "run"),
      project: live_project(workdir, check),
      provider_mod: ChatGPT,
      provider_config: provider_config,
      proc_mod: Kogen.Proc,
      env: %{},
      models: %{builder: {"gpt-6-luna", "low"}, strong: {"gpt-6.1-sol", "high"}},
      limits: %{max_turns: 12, wall_ms: 600_000},
      repairs_left: 2
    }
  end

  defp live_project(workdir, check) do
    %Project{
      root: workdir,
      name: "mini",
      checks: [check],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{"harness" => ["lib"]}
    }
  end

  defp live_selected? do
    ExUnit.configuration()
    |> Keyword.get(:include, [])
    |> Enum.any?(&(&1 == :live or match?({:live, _value}, &1)))
  end
end
