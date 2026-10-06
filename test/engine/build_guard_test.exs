defmodule Kogen.Engine.BuildGuardTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Tools
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc
  alias Kogen.Workspace

  test "rejects a changed protected file before checks run", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    protected_path = "checks.yml"
    original = "check: safe\n"
    File.write!(Path.join(repo, protected_path), original)
    git!(repo, ["add", protected_path])
    git!(repo, ["commit", "--quiet", "-m", "protect checks"])
    base_sha = repo |> git_output!(["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(repo, protected_path), "check: edited\n")

    manifest = %{protected_path => sha256(original)}

    assert {:error, %Failure{class: :candidate, reason: :protected_edit, detail: detail}} =
             Workspace.check_candidate(repo, base_sha, manifest, %{})

    assert detail =~ protected_path
  end

  test "rejects a protected file changed through the shell tool", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    protected_path = "checks.yml"
    original = "check: safe\n"
    File.write!(Path.join(repo, protected_path), original)
    git!(repo, ["add", protected_path])
    git!(repo, ["commit", "--quiet", "-m", "protect checks"])
    base_sha = repo |> git_output!(["rev-parse", "HEAD"]) |> String.trim()

    project = %Project{
      root: repo,
      name: "guard-fixture",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [protected_path],
      domains: %{"kernel" => ["lib/kogen/kernel"]}
    }

    opts = %Opts{
      workdir: repo,
      run_dir: Path.join(tmp_dir, "run"),
      project: project,
      provider_mod: Kogen.Provider.Fake,
      provider_config: nil,
      proc_mod: Kogen.Proc,
      protected: [protected_path]
    }

    call = %ToolCall{
      id: "shell-protected-edit",
      name: "shell",
      arguments: %{"cmd" => "printf 'check: shell-edited\\n' > #{protected_path}"}
    }

    result = Tools.run(opts, call, [:shell])
    refute result.is_error
    assert File.read!(Path.join(repo, protected_path)) == "check: shell-edited\n"

    assert {:error, %Failure{class: :candidate, reason: :protected_edit, detail: detail}} =
             Workspace.check_candidate(
               repo,
               base_sha,
               %{protected_path => sha256(original)},
               %{}
             )

    assert detail =~ protected_path
  end

  test "reports an info-excluded untracked file as an out-of-scope warning", %{
    tmp_dir: tmp_dir
  } do
    origin = Git.create!(Path.join(tmp_dir, "origin"))
    base_sha = origin |> git_output!(["rev-parse", "HEAD"]) |> String.trim()
    workspace_root = Path.join([tmp_dir, ".kogen", "workspaces", "guard-fixture"])
    candidate_env = Git.env()

    assert {:ok, %{path: workdir}} =
             Workspace.create(origin, base_sha, workspace_root, "guard-run", candidate_env)

    File.write!(Path.join(workdir, "hidden.txt"), "still changed\n")
    File.write!(Path.join(workdir, ".git/info/exclude"), "hidden.txt\n")

    project = %Project{
      root: origin,
      name: "guard-fixture",
      checks: [],
      setup: [],
      fix: [],
      diagnose: [],
      protected_paths: [],
      domains: %{"kernel" => ["lib/kogen/kernel"]}
    }

    intent = %Intent{
      slug: "guard-fixture",
      title: "Guard fixture",
      size: :small,
      brief: "Detect changes hidden by Candidate Git metadata.",
      acceptance: [],
      domains: ["kernel"],
      notes: nil,
      path: "guard-fixture/intent.md",
      sha256: String.duplicate("a", 64)
    }

    assert :ok = Workspace.check_candidate(workdir, base_sha, %{}, candidate_env)

    assert {:ok,
            [
              %{
                path: "hidden.txt",
                declared_domains: ["kernel"],
                finding: finding
              }
            ]} = Workspace.scope_warnings(workdir, base_sha, intent, project, candidate_env)

    assert finding =~ "hidden.txt"
    assert finding =~ "kernel"
  end

  defp git!(repo, args), do: Proc.cmd!("git", ["-C", repo | args], env: git_env())

  defp git_output!(repo, args), do: Proc.cmd!("git", ["-C", repo | args], env: git_env())

  defp git_env do
    [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_AUTHOR_NAME", "Kogen Test"},
      {"GIT_AUTHOR_EMAIL", "test@kogen.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Test"},
      {"GIT_COMMITTER_EMAIL", "test@kogen.invalid"}
    ]
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
