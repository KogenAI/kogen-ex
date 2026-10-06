defmodule Kogen.Harness.GateTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts

  test "same-seed failed-test rerun is excused only with matching base evidence", %{
    tmp_dir: tmp_dir
  } do
    write_test_source!(tmp_dir)
    Process.put(:gate_script_results, [{1, failed_output()}, {0, "1 test, 0 failures"}])

    base_argv =
      fn argv, _timeout ->
        Process.put(:gate_base_argv, argv)
        {:ok, process_result(argv, 1, failed_output())}
      end

    opts = options(tmp_dir, base_argv, fn -> {:ok, ["README.md"]} end)

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :pass
    assert result.failed_test_count == 0
    assert [%{test_ids: ["test/sample_test.exs:12"], seed: seed}] = result.flake_excused
    assert is_integer(seed)

    [{first_argv, _first_options}, {retry_argv, _retry_options}] =
      Enum.reverse(Process.get(:gate_command_calls))

    assert first_argv == ["mix", "test", "--seed", Integer.to_string(seed)]

    assert retry_argv == [
             "mix",
             "test",
             "test/sample_test.exs:12",
             "--seed",
             Integer.to_string(seed)
           ]

    assert Process.get(:gate_base_argv) == retry_argv
  end

  test "a red gate reports distinct failing ExUnit tests", %{tmp_dir: tmp_dir} do
    write_test_source!(tmp_dir)
    output = two_failed_output()
    Process.put(:gate_script_results, [{1, output}, {1, output}])

    opts = options(tmp_dir, nil, nil)

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :fail
    assert result.failed_test_count == 2
  end

  @tag :seatbelt
  test "persistent failures on the clean base are excused", %{
    tmp_dir: tmp_dir
  } do
    write_test_source!(tmp_dir)
    output = two_failed_output()
    Process.put(:gate_script_results, [{1, output}, {1, output}])

    base_test = fn argv, _timeout ->
      Process.put(:gate_base_argv, argv)
      {:ok, process_result(argv, 1, output)}
    end

    opts = options(tmp_dir, base_test, fn -> {:ok, ["lib/tiny_app/component.ex"]} end)

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :pass
    assert result.flake_excused == []
    assert [%{base_red?: true, output: detail}] = result.checks
    assert detail =~ "base-red"
    assert detail =~ "configured sandbox"
    assert detail =~ "test/sample_test.exs:12"

    [{_first_argv, _first_options}, {retry_argv, _retry_options}] =
      Enum.reverse(Process.get(:gate_command_calls))

    assert Process.get(:gate_base_argv) == retry_argv
  end

  test "compile errors from mix test have no comparable failed-test count", %{tmp_dir: tmp_dir} do
    write_test_source!(tmp_dir)

    Process.put(
      :gate_script_results,
      [{1, "** (SyntaxError) lib/sample.ex:3:1: syntax error before: end\n"}]
    )

    opts = options(tmp_dir, nil, nil)

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :fail
    assert is_nil(result.failed_test_count)
  end

  test "more than two excused tests in a Build leave the gate red", %{tmp_dir: tmp_dir} do
    write_test_source!(tmp_dir)
    Process.put(:gate_script_results, [{1, failed_output()}, {0, "1 test, 0 failures"}])

    opts =
      tmp_dir
      |> options(fn argv, _timeout -> {:ok, process_result(argv, 1, failed_output())} end, fn ->
        {:ok, ["README.md"]}
      end)
      |> Map.put(:flake_excused_test_ids, ["test/one_test.exs:1", "test/two_test.exs:2"])

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :fail
    assert result.flake_excused == []
    assert Enum.any?(result.failures, &String.contains?(&1, "test/sample_test.exs:12"))
  end

  test "a passing base rerun does not excuse a failure reached by the Candidate", %{
    tmp_dir: tmp_dir
  } do
    write_test_source!(tmp_dir)
    Process.put(:gate_script_results, [{1, failed_output()}, {0, "1 test, 0 failures"}])

    opts =
      options(
        tmp_dir,
        fn argv, _timeout -> {:ok, process_result(argv, 0, "1 test, 0 failures")} end,
        fn -> {:ok, ["lib/tiny_app/component.ex"]} end
      )

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :fail
    assert result.flake_excused == []
  end

  test "an unavailable check returns model repair feedback", %{
    tmp_dir: tmp_dir
  } do
    Process.put(:gate_script_results, [{1, "mix: command not found\n"}])
    opts = options(tmp_dir, fn _argv, _timeout -> {:ok, process_result([], 0, "")} end, nil)

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :fail
    assert [%{exit_level: 1}] = result.checks
    assert [detail] = result.failures
    assert detail =~ "mix is not available, but it ran on the base"
    refute detail =~ "[exunit/"
  end

  test "the gate formatter checks protected tests without rewriting them", %{tmp_dir: tmp_dir} do
    workdir = Path.join(tmp_dir, "project")
    test_path = Path.join([workdir, "test", "acceptance", "probe_test.exs"])
    approved = "defmodule ProbeTest do\n  use ExUnit.Case, async: true\nend\n"
    File.mkdir_p!(Path.dirname(test_path))
    File.write!(test_path, approved)

    bin_dir = Path.join(tmp_dir, "bin")
    mix_path = Path.join(bin_dir, "mix")
    File.mkdir_p!(bin_dir)

    File.write!(mix_path, """
    #!/bin/sh
    if [ "$1" = "format" ] && [ "$2" = "--check-formatted" ]; then
      exit 0
    fi
    printf 'rewritten\\n' > test/acceptance/probe_test.exs
    exit 0
    """)

    File.chmod!(mix_path, 0o755)

    opts = options(tmp_dir, nil, nil)

    format_check = %CheckSpec{
      name: "format",
      argv: ["mix", "format", "--check-formatted"],
      timeout_ms: 5_000
    }

    project = %{opts.project | checks: [format_check]}
    path = bin_dir <> ":/usr/bin:/bin:/usr/local/bin"
    opts = %{opts | proc_mod: Kogen.Proc, project: project, env: %{"PATH" => path}}

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :pass
    assert File.read!(test_path) == approved
  end

  test "a new format finding fails when the base already had another one", %{tmp_dir: tmp_dir} do
    format_check = %CheckSpec{
      name: "format",
      argv: ["mix", "format", "--check-formatted"],
      timeout_ms: 5_000
    }

    old_finding = %{
      tool: "format",
      rule: "unformatted",
      severity: :error,
      path: "lib/old.ex",
      line: 1,
      col: 1,
      symbol: nil,
      message: "run mix format <path>"
    }

    baseline =
      CheckBaseline.from_assessments([
        %{name: "format", exit_level: 1, findings: [old_finding]}
      ])

    Process.put(:gate_script_results, [{1, format_output(["lib/old.ex", "lib/new.ex"])}])
    opts = options(tmp_dir, nil, nil)
    opts = %{opts | project: %{opts.project | checks: [format_check]}, check_baseline: baseline}

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :fail
    assert [%{base_red?: false}] = result.checks
    assert [failure] = result.failures
    assert failure =~ "lib/new.ex"
  end

  test "a subset of base format findings is warned and excluded from the verdict", %{
    tmp_dir: tmp_dir
  } do
    format_check = %CheckSpec{
      name: "format",
      argv: ["mix", "format", "--check-formatted"],
      timeout_ms: 5_000
    }

    old_finding = %{
      tool: "format",
      rule: "unformatted",
      severity: :error,
      path: "lib/old.ex",
      line: 1,
      col: 1,
      symbol: nil,
      message: "run mix format <path>"
    }

    baseline =
      CheckBaseline.from_assessments([
        %{
          name: "format",
          exit_level: 1,
          findings: [old_finding, %{old_finding | path: "lib/older.ex"}]
        }
      ])

    Process.put(:gate_script_results, [{1, format_output(["lib/old.ex"])}])
    opts = options(tmp_dir, nil, nil)
    opts = %{opts | project: %{opts.project | checks: [format_check]}, check_baseline: baseline}

    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :pass
    assert result.failures == []
    assert [%{base_red?: true}] = result.checks
    assert [warning] = result.warnings
    assert warning =~ "lib/old.ex"
  end

  test "a failed fix is repair feedback even when the check passes", %{tmp_dir: tmp_dir} do
    Process.put(:gate_script_results, [{7, "formatter tail"}, {0, "1 test, 0 failures"}])
    opts = options(tmp_dir, nil, nil)
    fix = %CheckSpec{name: "formatter", argv: ["formatter"], timeout_ms: 5_000}
    opts = %{opts | project: %{opts.project | fix: [fix]}}
    assert {:ok, result} = Gate.run(opts, deadline())
    assert result.status == :fail
    assert [detail] = result.failures
    assert detail =~ "fix/formatter exited 7"
    assert detail =~ "formatter tail"
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
      proc_mod: Kogen.Harness.GateTest.ScriptedProc,
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

  defp two_failed_output do
    """

      1) test first failure (SampleTest)
         test/sample_test.exs:12
         ** (RuntimeError) first

      2) test second failure (OtherTest)
         test/other_test.exs:21
         ** (RuntimeError) second
    """
  end

  defp format_output(paths) do
    "** (Mix) mix format failed due to --check-formatted.\n" <>
      "The following files are not formatted:\n" <>
      Enum.map_join(paths, "\n", &("  " <> &1)) <> "\n"
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

defmodule Kogen.Harness.GateTest.ScriptedProc do
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
