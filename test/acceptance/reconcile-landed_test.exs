defmodule Kogen.Acceptance.ReconcileLandedTest do
  use Kogen.Testkit.Case

  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.Testkit.Proc

  @moduletag :acceptance
  @project_root Path.expand("../..", __DIR__)
  @git_env %{
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_AUTHOR_NAME" => "Kogen Test",
    "GIT_AUTHOR_EMAIL" => "test@kogen.invalid",
    "GIT_COMMITTER_NAME" => "Kogen Test",
    "GIT_COMMITTER_EMAIL" => "test@kogen.invalid"
  }
  @dead_pid 999_999

  @tag intent: "reconcile-landed/A1"
  test "status closes a crash after landing as landed", %{tmp_dir: tmp_dir} do
    {repo, branch, run} = crashed_run(tmp_dir, @dead_pid)
    land!(repo, run, branch, true)

    cli(["status", "--base", branch], repo)
    assert run_json(run)["status"] == "landed"
  end

  @tag intent: "reconcile-landed/A2"
  test "closing a landed crash releases the claim", %{tmp_dir: tmp_dir} do
    {repo, branch, run} = crashed_run(tmp_dir, @dead_pid)
    land!(repo, run, branch, true)

    cli(["status", "--base", branch], repo)

    assert git(repo, ["for-each-ref", "refs/kogen/claim"]) == ""
  end

  @tag intent: "reconcile-landed/A3"
  test "a crash whose landing commit is not on the branch is crashed", %{tmp_dir: tmp_dir} do
    {repo, branch, run} = crashed_run(tmp_dir, @dead_pid)
    land!(repo, run, branch, false)

    cli(["status", "--base", branch], repo)
    assert run_json(run)["status"] == "failed"
  end

  defp land!(repo, run, branch, on_branch?) do
    base = repo |> git(["rev-parse", "HEAD"]) |> String.trim()
    git(repo, ["commit", "--quiet", "--allow-empty", "-m", "Landed candidate"])
    candidate = repo |> git(["rev-parse", "HEAD"]) |> String.trim()
    tree = repo |> git(["rev-parse", "HEAD^{tree}"]) |> String.trim()

    if !on_branch? do
      git(repo, ["update-ref", "refs/heads/#{branch}", base, candidate])
      git(repo, ["checkout", "--quiet", "--detach", candidate])
    end

    :ok =
      State.put_landing(run, %{
        approval_commit: "approval",
        expected_parent: base,
        final_tree: tree,
        candidate_commit: candidate
      })
  end

  defp crashed_run(tmp_dir, owner_pid) do
    {repo, branch} = project(tmp_dir)
    approved = approval(repo)
    {:ok, _approval_commit} = State.approve(repo, approved, @git_env)
    {:ok, run} = State.start_run(Path.join(repo, ".kogen"), approved)
    :ok = State.claim(repo, run.id, @git_env)

    run_json_path = Path.join(run.dir, "run.json")
    decoded = run_json_path |> File.read!() |> :json.decode()

    File.write!(
      run_json_path,
      IO.iodata_to_binary(:json.encode(Map.put(decoded, "owner_os_pid", owner_pid)))
    )

    {repo, branch, run}
  end

  defp project(tmp_dir) do
    repo = Kogen.Testkit.Git.create!(tmp_dir)
    project_yaml = Path.join(repo, ".kogen/project.yaml")
    File.mkdir_p!(Path.dirname(project_yaml))
    File.cp!(Path.join(@project_root, ".kogen/project.yaml"), project_yaml)
    branch = repo |> git(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()
    {repo, branch}
  end

  defp approval(repo) do
    bytes = "---\ntitle: Probe\ndomains: [kernel]\nsize: small\n---\nProbe.\n"
    base = repo |> git(["rev-parse", "HEAD"]) |> String.trim()
    branch = repo |> git(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()

    %Approval{
      slug: "probe",
      intent_bytes: bytes,
      intent_sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
      target_branch: branch,
      base_sha: base,
      domains: ["kernel"],
      acceptance_files: %{},
      protected_manifest: %{},
      by: "acceptance test",
      at: ~U[2026-10-03 00:00:00Z]
    }
  end

  defp run_json(run), do: run.dir |> Path.join("run.json") |> File.read!() |> :json.decode()

  defp git(repo, args), do: Proc.cmd!("git", ["-C", repo | args], env: Map.to_list(@git_env))

  defp cli(args, cd) do
    Proc.cmd!("elixir", child_args() ++ ["-e", "Kogen.Kernel.CLI.main(#{inspect(args)})"], cd: cd)
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
