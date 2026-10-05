defmodule Kogen.Acceptance.ReconcileReportTest do
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

  @tag intent: "reconcile-report/A1"
  test "status reports a crashed run as failed with reason crashed", %{tmp_dir: tmp_dir} do
    {repo, branch, run} = crashed_run(tmp_dir, @dead_pid)

    output = cli(["status", "--base", branch], repo)

    assert output =~ ~r/^Failed:\n  probe  crashed \(Build #{binary_part(run.id, 0, 8)}\)$/m
  end

  @tag intent: "reconcile-report/A2"
  test "status removes a crashed run's workspace", %{tmp_dir: tmp_dir} do
    {repo, branch, run} = crashed_run(tmp_dir, @dead_pid)
    workspace = workspace!(repo, run)

    cli(["status", "--base", branch], repo)

    refute File.exists?(workspace)
    assert run_json(run)["status"] == "failed"
  end

  @tag intent: "reconcile-report/A3"
  test "status leaves a live run building and keeps its workspace", %{tmp_dir: tmp_dir} do
    {repo, branch, run} = crashed_run(tmp_dir, String.to_integer(System.pid()))
    workspace = workspace!(repo, run)

    assert cli(["status", "--base", branch], repo) =~ ~r/^Building:\n  probe  /m
    assert File.exists?(Path.join(workspace, "marker"))
  end

  defp workspace!(repo, run) do
    workspace = Path.join([repo, ".kogen", "w", run.id])
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "marker"), "candidate")
    workspace
  end

  defp crashed_run(tmp_dir, owner_pid) do
    {repo, branch} = project(tmp_dir)
    approved = approval(repo)
    {:ok, approval_commit} = State.approve(repo, approved, @git_env)
    {:ok, run} = State.start_run(Path.join(repo, ".kogen"), approved)
    :ok = State.claim(repo, run.id, @git_env)

    run_json_path = Path.join(run.dir, "run.json")
    decoded = run_json_path |> File.read!() |> :json.decode()

    decoded =
      Map.merge(decoded, %{"owner_os_pid" => owner_pid, "approval_commit" => approval_commit})

    File.write!(run_json_path, IO.iodata_to_binary(:json.encode(decoded)))

    {repo, branch, run}
  end

  defp project(tmp_dir) do
    repo = Kogen.Testkit.Git.create!(tmp_dir)
    project_yaml = Path.join(repo, ".kogen/project.yaml")
    File.mkdir_p!(Path.dirname(project_yaml))
    File.cp!(Path.join(@project_root, ".kogen/project.yaml"), project_yaml)
    branch = repo |> git(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()
    intent = Path.join(repo, ".kogen/intents/probe/intent.md")
    File.mkdir_p!(Path.dirname(intent))
    File.write!(intent, "---\ntitle: Probe\ndomains: [kernel]\nsize: small\n---\nProbe.\n")
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
