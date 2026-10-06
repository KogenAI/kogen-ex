defmodule Kogen.Harness.GateTimingTest do
  use Kogen.Testkit.Case

  import ExUnit.CaptureIO

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts
  alias Kogen.Testkit.HarnessScriptedProvider

  test "a passing suite over both budgets stays passing and retains duration and slowest stage",
       %{tmp_dir: root} do
    Process.put(:timed_gate_result, {0, false, 70_000})

    output =
      capture_io(:stderr, fn ->
        assert {:ok, gate} = Gate.run(opts(root), deadline())
        assert gate.status == :pass
        assert gate.failures == []
        assert gate.flake_excused == []
        assert gate.timing.duration_ms >= 70_000
        assert gate.timing.test_duration_ms == 70_000
        assert gate.timing.slowest_stage == %{name: "tests", duration_ms: 70_000}
      end)

    assert output =~ "test suite took 70000 ms"
    assert output =~ "complete check took"
    assert output =~ "slowest stage: tests 70000 ms"
    assert output =~ "Correctness is unchanged"

    [receipt] =
      root
      |> Path.join("run/gate-timings.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)

    assert receipt["test_duration_ms"] == 70_000
    assert receipt["slowest_stage"] == %{"name" => "tests", "duration_ms" => 70_000}
  end

  test "a timed out command remains a failure and is distinct from the budget advice", %{
    tmp_dir: root
  } do
    Process.put(:timed_gate_result, {nil, true, 70_000})

    capture_io(:stderr, fn ->
      assert {:ok, gate} = Gate.run(opts(root), deadline())
      assert gate.status == :fail
      assert Enum.join(gate.failures) =~ "timed out"
      assert Enum.join(gate.warnings) =~ "advisory budget"
    end)
  end

  test "a failed command keeps its exit evidence when it also exceeds the budget", %{
    tmp_dir: root
  } do
    Process.put(:timed_gate_result, {7, false, 70_000})

    capture_io(:stderr, fn ->
      assert {:ok, gate} = Gate.run(opts(root), deadline())
      assert gate.status == :fail
      assert [%{exit_status: 7, timed_out: false}] = gate.checks
      assert gate.failures != []
    end)
  end

  test "over-budget diagnostics retain changed-file feedback and their complete report", %{
    tmp_dir: root
  } do
    Process.put(:timed_gate_result, {2, false, 70_000})

    Process.put(
      :timed_gate_output,
      "Total errors: 1, Skipped: 0, Unnecessary Skips: 0\n" <>
        "lib/changed.ex:20:pattern_match\nReturn shape cannot match.\n"
    )

    options = %{
      opts(root)
      | changed_paths: fn -> {:ok, ["lib/changed.ex"]} end,
        changed_ranges: fn -> {:ok, ["lib/changed.ex: base 20 -> candidate 20-30"]} end
    }

    capture_io(:stderr, fn ->
      assert {:ok, gate} = Gate.run(options, deadline())
      assert gate.status == :fail
      assert gate.timing.test_duration_ms == 70_000
      assert gate.dialyzer_summary.changed == 1
      assert Enum.join(gate.failures) =~ "lib/changed.ex: base 20 -> candidate 20-30"
      assert Enum.join(gate.failures) =~ "complete findings: #{gate.findings_path}"
      assert [%{"line" => 20}] = Jason.decode!(File.read!(gate.findings_path))["findings"]
    end)
  end

  test "a budget warning completes the Developer with zero correctness repairs", %{tmp_dir: root} do
    Process.put(:timed_gate_result, {0, false, 70_000})

    provider =
      HarnessScriptedProvider.start([
        %Kogen.Contracts.ModelResponse{
          id: "done",
          text: "Done.",
          tool_calls: [%Kogen.Contracts.ToolCall{id: "finish", name: "finish", arguments: %{}}],
          usage: %{},
          raw_items: []
        }
      ])

    options = %{
      opts(root)
      | provider_mod: HarnessScriptedProvider,
        provider_config: provider,
        changed?: fn -> {:ok, true} end
    }

    capture_io(:stderr, fn ->
      assert {:ok, result} =
               Kogen.Harness.develop(options, "Complete the approved change.", nil, nil, 0)

      assert result.outcome == :done
      assert result.turns == 1
      assert result.gate.status == :pass
      assert result.gate.warnings != []
      assert length(HarnessScriptedProvider.requests(provider)) == 1
    end)
  end

  defp opts(root) do
    workdir = Path.join(root, "worktree")
    File.mkdir_p!(workdir)

    %Opts{
      workdir: workdir,
      run_dir: Path.join(root, "run"),
      project: %Project{
        root: root,
        name: "timing",
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{},
        checks: [%CheckSpec{name: "tests", argv: ["test-program"], timeout_ms: 900_000}]
      },
      provider_mod: __MODULE__,
      provider_config: nil,
      env: %{
        "TEST_GATE_RESULT" =>
          :timed_gate_result |> Process.get() |> Tuple.to_list() |> Jason.encode!(),
        "TEST_GATE_OUTPUT" => Process.get(:timed_gate_output, "measured command output")
      },
      proc_mod: __MODULE__.MeasuredProc
    }
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 900_000
end

defmodule Kogen.Harness.GateTimingTest.MeasuredProc do
  @moduledoc false
  alias Kogen.Contracts.ProcResult

  def run(argv, opts) do
    env = Keyword.fetch!(opts, :env)
    [status, timed_out, duration] = env |> Map.fetch!("TEST_GATE_RESULT") |> Jason.decode!()

    {:ok,
     %ProcResult{
       argv: argv,
       exit_status: status,
       timed_out: timed_out,
       duration_ms: duration,
       output_tail: Map.fetch!(env, "TEST_GATE_OUTPUT"),
       log_path: Keyword.get(opts, :log_path)
     }}
  end
end
