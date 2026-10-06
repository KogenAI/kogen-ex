defmodule Kogen.Harness.FlakeEvidenceTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts

  test "a passing or unavailable base cannot excuse an apparently untouched Candidate flake", %{
    tmp_dir: tmp
  } do
    write_test_source!(tmp)

    for base <- [
          fn argv, _ -> {:ok, process_result(argv, 0, "1 test, 0 failures")} end,
          nil,
          fn argv, _ -> {:ok, %{process_result(argv, 1, failed_output()) | timed_out: true}} end
        ] do
      Process.put(:gate_script_results, [{1, failed_output()}, {0, "1 test, 0 failures"}])
      opts = options(tmp, base, fn -> {:ok, ["README.md"]} end)
      assert {:ok, gate} = Gate.run(opts, deadline())
      assert gate.status == :fail
      assert gate.flake_excused == []
      assert Enum.join(gate.failures) =~ "remain Candidate failures"
    end

    reports = Path.wildcard(Path.join(tmp, "run/flake-evidence-*.json"))
    assert length(reports) == 3

    for file <- reports do
      report = file |> File.read!() |> JSON.decode!()
      assert report["test_ids"] == ["test/sample_test.exs:12"]
      assert report["classification"] in ["candidate_flake", "unconfirmed_flake"]
      assert report["candidate"]["exit_status"] == 1
      assert report["candidate_retry"]["exit_status"] == 0
      assert Integer.to_string(report["seed"]) in report["base"]["argv"]
      assert report["excused_test_ids"] == []
    end
  end

  test "missing durable evidence keeps a confirmed base flake red", %{tmp_dir: tmp} do
    write_test_source!(tmp)
    Process.put(:gate_script_results, [{1, failed_output()}, {0, "1 test, 0 failures"}])
    opts = options(tmp, fn argv, _ -> {:ok, process_result(argv, 1, failed_output())} end, nil)
    opts = %{opts | event_recorder: fn _ -> {:error, :injected_journal_failure} end}
    assert {:ok, gate} = Gate.run(opts, deadline())
    assert gate.status == :fail
    assert gate.flake_excused == []
    assert Enum.join(gate.failures) =~ "could not be recorded"
  end

  defp options(tmp_dir, base_test, changed_paths) do
    workdir = Path.join(tmp_dir, "project")
    File.mkdir_p!(workdir)
    spec = %CheckSpec{name: "tests", argv: ["mix", "test"], timeout_ms: 5_000}

    project = %Project{
      root: workdir,
      name: "gate-test",
      checks: [spec],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{}
    }

    %Opts{
      workdir: workdir,
      run_dir: Path.join(tmp_dir, "run"),
      project: project,
      provider_mod: __MODULE__,
      provider_config: nil,
      proc_mod: Kogen.Harness.FlakeEvidenceTest.ScriptedProc,
      base_test: base_test,
      changed_paths: changed_paths
    }
  end

  defp write_test_source!(tmp_dir) do
    path = Path.join([tmp_dir, "project", "test", "sample_test.exs"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    defmodule SampleTest do
      use ExUnit.Case
      alias TinyApp.Component

      test "sample" do
        Component.run()
      end
    end
    """)
  end

  defp failed_output do
    """

      1) test sample (SampleTest)
         test/sample_test.exs:12
         ** (RuntimeError) flaky
    """
  end

  defp process_result(argv, status, output) do
    %ProcResult{
      argv: argv,
      exit_status: status,
      timed_out: false,
      output_tail: output,
      log_path: nil,
      duration_ms: 0
    }
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 10_000
end

defmodule Kogen.Harness.FlakeEvidenceTest.ScriptedProc do
  @moduledoc false
  alias Kogen.Contracts.ProcResult

  def run(argv, options) do
    calls = Process.get(:gate_command_calls, [])
    Process.put(:gate_command_calls, [{argv, options} | calls])

    case Process.get(:gate_script_results, []) do
      [{status, output} | rest] ->
        Process.put(:gate_script_results, rest)

        {:ok,
         %ProcResult{
           argv: argv,
           exit_status: status,
           timed_out: false,
           output_tail: output,
           log_path: Keyword.get(options, :log_path),
           duration_ms: 0
         }}

      [] ->
        {:error, :script_exhausted}
    end
  end
end
