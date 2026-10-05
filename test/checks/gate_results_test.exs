defmodule Kogen.Checks.GateResultsTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Checks
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Testkit.Git

  test "a timeout feeds its duration and output tail back, and only a base timeout excuses it", %{
    tmp_dir: tmp_dir
  } do
    repo = Git.create!(tmp_dir)

    spec = %CheckSpec{
      name: "slow",
      argv: ["/bin/sh", "-c", "echo waiting-for-repair; sleep 5"],
      timeout_ms: 100
    }

    assert {:ok, red} = run(repo, tmp_dir, [spec], [])
    assert red.status == {:fail, ["slow"]}
    assert red.feedback =~ "timed out after 0.1 s"
    assert red.feedback =~ "waiting-for-repair"
    baseline = CheckBaseline.from_assessments(red.checks)
    assert {:ok, excused} = run(repo, tmp_dir, [spec], baseline)
    assert excused.status == :pass
    assert excused.warnings != []
    missing = %{spec | argv: ["missing-kogen-test-program"], timeout_ms: 1_000}
    assert {:ok, changed_status} = run(repo, tmp_dir, [missing], baseline)
    assert changed_status.status == {:fail, ["slow"]}

    assert changed_status.feedback =~
             "missing-kogen-test-program is not available, but it ran on the base"
  end

  test "base check writes are reverted, preserving candidate bytes, modes and the index", %{
    tmp_dir: tmp_dir
  } do
    repo = Git.create!(tmp_dir)
    script = "printf generated > generated.txt; printf replaced > README.md; chmod +x README.md"
    spec = %CheckSpec{name: "write", argv: ["/bin/sh", "-c", script], timeout_ms: 1_000}
    assert {:ok, base} = run(repo, tmp_dir, [spec], [])
    assert base.status == {:fail, ["write"]}
    assert base.feedback =~ "generated.txt"
    baseline = CheckBaseline.from_assessments(base.checks)
    File.rm!(Path.join(repo, "generated.txt"))
    File.write!(Path.join(repo, "README.md"), "candidate bytes\n")
    File.chmod!(Path.join(repo, "README.md"), 0o644)
    index = File.read!(Path.join(repo, ".git/index"))
    assert {:ok, excused} = run(repo, tmp_dir, [spec], baseline)
    assert excused.status == :pass
    assert File.read!(Path.join(repo, "README.md")) == "candidate bytes\n"
    assert Bitwise.band(File.stat!(Path.join(repo, "README.md")).mode, 0o777) == 0o644
    refute File.exists?(Path.join(repo, "generated.txt"))
    assert File.read!(Path.join(repo, ".git/index")) == index
  end

  test "approval records failing fixes and both fix paths excuse only the same base result", %{
    tmp_dir: tmp_dir
  } do
    repo = Git.create!(tmp_dir)

    spec = %CheckSpec{
      name: "format",
      argv: ["/bin/sh", "-c", "echo fix-tail; exit 7"],
      timeout_ms: 1_000
    }

    project = %{project(repo, []) | fix: [spec]}
    run_dir = Path.join(tmp_dir, "approval")

    assert {:ok, base} =
             Checks.run_all(repo, project, run_dir, Git.env(), Git.env(), %{baseline_run?: true})

    assert base.feedback =~ "fix/format"
    assert base.feedback =~ "fix-tail"
    baseline = CheckBaseline.from_assessments(base.checks)
    assert {:ok, _results} = Checks.fix(repo, project, run_dir, Git.env(), nil, baseline)
    changed = %{project | fix: [%{spec | argv: ["/bin/sh", "-c", "exit 8"]}]}
    assert {:error, failure} = Checks.fix(repo, changed, run_dir, Git.env(), nil, baseline)
    assert failure.class == :candidate
    assert failure.detail =~ "fix/format exited 8"
  end

  defp run(repo, tmp_dir, specs, baseline) do
    dir = Path.join(tmp_dir, "run-#{System.unique_integer([:positive])}")

    Checks.run_all(repo, project(repo, specs), dir, Git.env(), Git.env(), %{
      check_baseline: baseline
    })
  end

  defp project(repo, specs),
    do: %Project{
      root: repo,
      name: "gate-results",
      checks: specs,
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{}
    }
end
