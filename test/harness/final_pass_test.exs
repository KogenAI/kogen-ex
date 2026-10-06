defmodule Kogen.Harness.FinalPassTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts
  alias Kogen.Testkit.Git

  test "the done gate and controller share one pass, and repaired trees get a fresh pass", %{
    tmp_dir: tmp
  } do
    opts =
      options(tmp, "printf x >> .git/fix-calls; printf formatted > formatted.txt; echo fixed")

    assert {:ok, first} = Gate.run(opts, deadline())
    assert first.status == :pass
    assert File.read!(Path.join(opts.workdir, "formatted.txt")) == "formatted"
    assert {:ok, fixes} = final_pass(opts)
    assert :ok = Checks.final_pass_passed(fixes)
    Git.git!(opts.workdir, ["add", "--all"])
    tree = String.trim(Git.git!(opts.workdir, ["write-tree"]))
    assert {:ok, [receipt]} = Checks.final_pass_receipts(tree, opts.project, fixes)
    assert receipt.check == "fix/format"
    assert receipt.exit_status == 0
    assert receipt.tree == tree
    assert receipt.duration_ms == hd(first.fixes).duration_ms
    assert {:ok, again} = Gate.run(opts, deadline())
    assert again.status == :pass
    assert File.read!(Path.join(opts.workdir, ".git/fix-calls")) == "x"
    File.write!(Path.join(opts.workdir, "repaired.txt"), "new candidate revision")
    assert {:ok, repaired} = Gate.run(opts, deadline())
    assert repaired.status == :pass
    assert File.read!(Path.join(opts.workdir, ".git/fix-calls")) == "xx"
    assert File.read!(Path.join(opts.workdir, ".git/check-calls")) == "xxx"
    assert {:ok, cached} = final_pass(opts)
    assert cached == repaired.fixes
    assert File.read!(Path.join(opts.workdir, ".git/fix-calls")) == "xx"
  end

  test "a red fixer remains visible on rechecks and reruns only after a repair", %{tmp_dir: tmp} do
    opts = options(tmp, "printf x >> .git/fix-calls; echo unable-to-format; exit 7")

    for _ <- 1..2 do
      assert {:ok, result} = Gate.run(opts, deadline())
      assert result.status == :fail
      assert Enum.join(result.failures) =~ "fix/format"
      assert Enum.join(result.failures) =~ "unable-to-format"
      assert {:ok, fixes} = final_pass(opts)
      assert {:error, failure} = Checks.final_pass_passed(fixes)
      assert failure.reason == :fix_failed
    end

    assert File.read!(Path.join(opts.workdir, ".git/fix-calls")) == "x"
    File.write!(Path.join(opts.workdir, "repaired.txt"), "retry tool on revised candidate")
    assert {:ok, %{status: :fail}} = Gate.run(opts, deadline())
    assert File.read!(Path.join(opts.workdir, ".git/fix-calls")) == "xx"
  end

  test "each revision retains its own fix log and receipt", %{tmp_dir: tmp} do
    opts = options(tmp, "printf x >> .git/fix-calls; wc -c < .git/fix-calls")
    assert {:ok, [first]} = final_pass(opts)
    assert is_integer(first.duration_ms) and first.duration_ms >= 0
    old_log = File.read!(first.log_path)
    assert String.trim(old_log) == "1"
    File.write!(Path.join(opts.workdir, "revision.txt"), "repair")
    assert {:ok, [second]} = final_pass(opts)
    assert String.trim(File.read!(second.log_path)) == "2"
    assert first.log_path != second.log_path
    assert File.read!(first.log_path) == old_log
    assert {:ok, [receipt]} = Checks.final_pass_receipts("tree", opts.project, [first])
    assert receipt.duration_ms == first.duration_ms
    assert {:ok, [^second]} = final_pass(opts)
    assert File.read!(Path.join(opts.workdir, ".git/fix-calls")) == "xx"
  end

  defp final_pass(opts),
    do: Checks.final_pass(opts.workdir, opts.project, opts.run_dir, opts.env, nil, [])

  defp options(tmp, fix) do
    repo = Git.create!(tmp)

    project = %Project{
      root: repo,
      name: "single-fix",
      setup: [],
      diagnose: [],
      protected_paths: [],
      domains: %{},
      fix: [%CheckSpec{name: "format", argv: ["sh", "-c", fix], timeout_ms: 5_000}],
      checks: [
        %CheckSpec{
          name: "check",
          argv: ["sh", "-c", "printf x >> .git/check-calls"],
          timeout_ms: 5_000
        }
      ]
    }

    %Opts{
      workdir: repo,
      run_dir: Path.join(tmp, "run"),
      project: project,
      provider_mod: __MODULE__,
      provider_config: %{},
      proc_mod: Kogen.Proc,
      env: Git.env()
    }
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 30_000
end
