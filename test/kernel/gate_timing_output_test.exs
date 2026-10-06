defmodule Kogen.Kernel.GateTimingOutputTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.GateTiming
  alias Kogen.Kernel.CLI.StatusOutput
  alias Kogen.Queue.BuildSummary
  alias Kogen.Queue.Report
  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.IntentFixture
  alias Kogen.Testkit.Proc

  @script Path.expand("../../tools/gate_timing.py", __DIR__)
  @external_resource @script

  test "status and the final report show identical measured evidence on a passing Build", %{
    tmp_dir: root
  } do
    repo = Git.create!(root)
    Git.git!(repo, ["branch", "-M", "main"])

    Git.git!(repo, [
      "commit",
      "--allow-empty",
      "--quiet",
      "-m",
      "Delivered\n\nKogen-Intent: timing-probe"
    ])

    bytes = IntentFixture.source()

    approval = %Approval{
      slug: "timing-probe",
      intent_bytes: bytes,
      intent_sha256: Kogen.Intent.hash(bytes),
      target_branch: "main",
      base_sha: String.trim(Git.git!(repo, ["rev-parse", "HEAD"])),
      domains: ["intent"],
      acceptance_files: %{},
      protected_manifest: %{},
      by: "test",
      at: ~U[2026-10-03 00:00:00Z]
    }

    state_root = Path.join(root, "state")
    assert {:ok, run} = State.start_run(state_root, approval)
    timing = GateTiming.summarize([%{name: "tests", duration_ms: 70_000}], 70_000)

    assert :ok =
             State.record(run, %{
               event: :check_result,
               timing: timing,
               result: :pass,
               receipts: [%{check: "tests", exit_status: 0, duration_ms: 70_000}]
             })

    assert :ok =
             State.record(run, %{
               event: :model_stage,
               stage: "audit",
               wall_ms: 2_000,
               gate_summary: %{timing: GateTiming.summarize([], 2_000)}
             })

    assert :ok = State.record(run, %{event: :finished, status: :landed})
    assert :ok = State.record(run, %{event: :context_continued})

    assert :ok =
             State.record(run, %{
               event: :acceptance_result,
               acceptance_items: [%{id: "A1", status: "passed"}],
               ledger: [%{tag: "timing-probe/A1", status: "passed"}]
             })

    proposal = Path.join(run.dir, "proposal.json")
    assert :ok = State.record(run, %{event: :setup_reused, saved_wall_ms: 42})
    assert :ok = State.record(run, %{event: :check_proposal_drafted, path: proposal})

    assert {:ok, summary} = BuildSummary.latest(state_root, "timing-probe")
    assert {:ok, bytes} = Report.read("timing-probe", state_root, repo, "main", Git.env())
    report = :json.decode(bytes)
    assert report["status"] == "landed"
    assert report["gate_timing"]["duration_ms"] == summary.gate_timing.duration_ms
    assert report["gate_timing"]["warnings"] == summary.gate_timing.warnings

    assert report["check_receipts"] == [
             %{"check" => "tests", "exit_status" => 0, "duration_ms" => 70_000}
           ]

    text = StatusOutput.build_text(summary)
    assert text =~ "duration 70000 ms; tests 70000 ms; slowest stage: tests 70000 ms"
    assert text =~ "Time budget warning"
    assert text =~ "landed"
    assert text =~ "context continuations: 1"
    assert text =~ "acceptance verified: A1"
    assert summary.progress == %{verified: ["A1"], remaining: []}
    assert report["progress"] == %{"verified" => ["A1"], "remaining" => []}
    assert summary.setup == %{reused?: true, wall_ms: 42}
    assert summary.check_proposals == [proposal]
    assert report["check_proposals"] == [proposal]

    assert report["setup"] == [
             %{"event" => "setup_reused", "wall_ms" => 0, "saved_wall_ms" => 42}
           ]

    assert text =~ "setup: reused (saved preparation 42 ms)"
    assert text =~ "candidate checks (caller approval required): #{proposal}"
  end

  test "the Make timing wrapper preserves success and writes a measured receipt", %{tmp_dir: root} do
    output =
      Proc.cmd!(
        "python3",
        [
          @script,
          "full",
          "probe",
          "--",
          "python3",
          @script,
          "stage",
          "test",
          "--",
          "/bin/sh",
          "-c",
          "echo passed"
        ],
        cd: root
      )

    assert output =~ "passed"
    assert output =~ "Gate timing (passed): duration"
    assert output =~ "slowest stage: test"

    receipt =
      root
      |> Path.join("_build/kogen-gate-timing/last-probe.json")
      |> File.read!()
      |> :json.decode()

    assert receipt["status"] == "passed"
    assert receipt["exit_status"] == 0
    assert is_integer(receipt["duration_ms"])
    assert [%{"name" => "test", "exit_status" => 0}] = receipt["stages"]
  end

  test "the timing wrapper keeps a failed command's exit status", %{tmp_dir: root} do
    assert {:ok, result} =
             Kogen.Proc.run(
               ["python3", @script, "full", "failure", "--", "/bin/sh", "-c", "exit 7"],
               cd: root
             )

    assert result.exit_status == 7
    assert result.output_tail =~ "Gate timing (failed)"

    receipt =
      root
      |> Path.join("_build/kogen-gate-timing/last-failure.json")
      |> File.read!()
      |> :json.decode()

    assert receipt["exit_status"] == 7
  end

  test "replaying an over-budget Make receipt warns without changing a passing result", %{
    tmp_dir: root
  } do
    path = Path.join(root, "receipt.json")

    File.write!(
      path,
      :json.encode(%{
        duration_ms: 70_000,
        test_duration_ms: 15_000,
        slowest_stage: %{name: "compile", duration_ms: 55_000},
        status: "passed",
        warnings: [
          "test suite took 15000 ms (10000 ms advisory budget)",
          "complete check took 70000 ms (60000 ms advisory budget)"
        ]
      })
    )

    assert {:ok, result} = Kogen.Proc.run(["python3", @script, "report", path], cd: root)
    assert result.exit_status == 0
    assert result.output_tail =~ "Gate timing (passed)"
    assert result.output_tail =~ "test suite took 15000 ms"
    assert result.output_tail =~ "complete check took 70000 ms"
    assert result.output_tail =~ "slowest stage: compile 55000 ms"
  end
end
