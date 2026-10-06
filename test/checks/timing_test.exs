defmodule Kogen.Checks.TimingTest do
  use Kogen.Testkit.Case

  import ExUnit.CaptureIO

  alias Kogen.Checks
  alias Kogen.Checks.Timing
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Testkit.Git

  test "final check receipts retain measured command durations", %{tmp_dir: root} do
    repo = Git.create!(root)

    project = %Project{
      root: repo,
      name: "timing",
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{},
      checks: [%CheckSpec{name: "tests", argv: ["/bin/sh", "-c", "exit 0"], timeout_ms: 10_000}]
    }

    run_dir = Path.join(root, "run")
    assert {:ok, result} = Checks.run_all(repo, project, run_dir, Git.env(), Git.env())
    assert result.status == :pass
    assert [%{duration_ms: duration}] = result.receipts
    assert is_integer(duration) and duration >= 0

    receipt =
      run_dir
      |> Path.join("gate-timings.jsonl")
      |> File.read!()
      |> String.trim()
      |> :json.decode()

    assert receipt["duration_ms"] == result.timing.duration_ms
    assert receipt["slowest_stage"]["name"] == "tests"
  end

  test "over-budget shape validation returns advisory warnings without becoming a repair failure",
       %{tmp_dir: root} do
    capture_io(:stderr, fn ->
      assert {:ok, warnings} =
               Timing.shape(root, fn ->
                 result = %ProcResult{
                   argv: ["mix", "test"],
                   exit_status: 0,
                   timed_out: false,
                   output_tail: "passed",
                   log_path: nil,
                   duration_ms: 70_000
                 }

                 assert {:ok, ^result} =
                          Timing.process({:ok, result}, root, "acceptance", result.argv)

                 {:ok, []}
               end)

      assert Enum.all?(warnings, &(&1.code == :gate_time_budget and &1.item_ids == []))
      assert Enum.any?(warnings, &String.contains?(&1.message, "complete check"))
    end)

    receipts =
      root
      |> Path.join("gate-timings.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)

    assert length(receipts) == 2
    assert List.last(receipts)["slowest_stage"]["name"] == "acceptance"
  end
end
