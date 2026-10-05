defmodule Kogen.Acceptance.ReconcileCrashedTest do
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

  @tag intent: "reconcile-crashed/A1"
  test "a crashed run is marked failed and its claim is released", %{tmp_dir: tmp_dir} do
    {repo, branch, run} = crashed_run(tmp_dir, @dead_pid)

    cli(["status", "--base", branch], repo)

    assert run_json(run)["status"] == "failed"
    assert run_events(run) =~ "crashed"
    assert claim_sha(repo) == nil
  end

  @tag intent: "reconcile-crashed/A2"
  test "a run whose owner is alive is left alone", %{tmp_dir: tmp_dir} do
    {repo, branch, run} = crashed_run(tmp_dir, String.to_integer(System.pid()))
    claim_before = claim_sha(repo)

    cli(["status", "--base", branch], repo)

    assert run_json(run)["status"] == "running"
    assert claim_sha(repo) == claim_before
    assert claim_before
  end

  @tag intent: "reconcile-crashed/A3"
  test "a started run records its owner pid", %{tmp_dir: tmp_dir} do
    {repo, _branch} = project(tmp_dir)
    {:ok, run} = State.start_run(Path.join(repo, ".kogen"), approval(repo))

    assert run_json(run)["owner_os_pid"] == String.to_integer(System.pid())
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

  defp claim_sha(repo) do
    case repo
         |> git(["for-each-ref", "--format=%(objectname)", "refs/kogen/claim"])
         |> String.trim() do
      "" -> nil
      sha -> sha
    end
  end

  defp run_json(run), do: run.dir |> Path.join("run.json") |> File.read!() |> :json.decode()
  defp run_events(run), do: run.dir |> Path.join("events.jsonl") |> File.read!()

  defp git(repo, args), do: Proc.cmd!("git", ["-C", repo | args], env: Map.to_list(@git_env))

  defp cli(args, cd) do
    Proc.cmd!("elixir", child_args() ++ ["-e", "Kogen.Kernel.CLI.main(#{inspect(args)})"], cd: cd)
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
