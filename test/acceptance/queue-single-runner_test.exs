defmodule Kogen.Acceptance.QueueSingleRunnerTest do
  use Kogen.Testkit.Case

  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc

  @moduletag :acceptance
  @project_root Path.expand("../..", __DIR__)
  @dead_pid 999_999
  @slug "queue-probe"
  @git_env %{
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_AUTHOR_NAME" => "Kogen Test",
    "GIT_AUTHOR_EMAIL" => "test@kogen.invalid",
    "GIT_COMMITTER_NAME" => "Kogen Test",
    "GIT_COMMITTER_EMAIL" => "test@kogen.invalid"
  }

  @intent_bytes """
  ---
  title: Queue probe
  domains: [queue]
  size: small
  ---
  Keep the approved queue probe unchanged.
  """

  @tag intent: "queue-single-runner/A1"
  test "a second start reports the active runner without touching its approved Intent", %{
    tmp_dir: tmp_dir
  } do
    {repo, branch, home, state_root} = project!(tmp_dir)
    approved = approval(repo, branch)
    assert {:ok, _approval_commit} = State.approve(repo, approved, @git_env)
    write_queue_pid!(state_root, String.to_integer(System.pid()))

    output =
      cli(["queue", "start", "--project", repo, "--origin", repo, "--base", branch], repo, home)

    assert output =~ "queue: already running"
    assert output =~ "pid #{System.pid()}"
    assert output =~ ~r/\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/
    assert {:ok, []} = State.list(state_root)
    assert {:ok, _approved} = State.approval(repo, @slug, @git_env)
  end

  @tag intent: "queue-single-runner/A2"
  test "a dead queue runner is taken over and its interrupted Build is recovered", %{
    tmp_dir: tmp_dir
  } do
    {repo, branch, home, state_root} = project!(tmp_dir)
    approved = approval(repo, branch)
    assert {:ok, _approval_commit} = State.approve(repo, approved, @git_env)
    assert {:ok, run} = State.start_run(state_root, approved)
    assert :ok = State.claim(repo, run.id, @git_env)
    assert :ok = State.record(run, %{event: :interrupted, reason: :sigterm})
    set_owner_pid(run, @dead_pid)
    write_queue_pid!(state_root, @dead_pid)

    output =
      cli(["queue", "start", "--project", repo, "--origin", repo, "--base", branch], repo, home)

    assert output =~ "queue:"
    assert {:ok, recovered} = State.load(state_root, run.id)
    assert recovered.status == :failed
    assert File.read!(Path.join(run.dir, "events.jsonl")) =~ "interrupted"
    assert claim_sha(repo) == ""
    refute File.exists?(Path.join(state_root, "queue.pid"))
  end

  @tag intent: "queue-single-runner/A3"
  test "status and stop remain available while the queue runner is active", %{tmp_dir: tmp_dir} do
    {repo, branch, home, state_root} = project!(tmp_dir)
    write_queue_pid!(state_root, String.to_integer(System.pid()))

    status = cli(["status", "--project", repo, "--origin", repo, "--base", branch], repo, home)

    stop =
      cli(["queue", "stop", "--project", repo, "--origin", repo, "--base", branch], repo, home)

    assert status =~ "Queue: running (pid #{System.pid()})"
    assert stop =~ "queue: stopping after the current Build (pid #{System.pid()})"
    assert File.exists?(Path.join(state_root, "queue.stop"))
  end

  defp project!(tmp_dir) do
    repo = Git.create!(Path.join(tmp_dir, "project"))
    File.mkdir_p!(Path.join(repo, ".kogen"))

    File.cp!(
      Path.join([@project_root, ".kogen", "project.yaml"]),
      Path.join([repo, ".kogen", "project.yaml"])
    )

    intent_path = Path.join([repo, ".kogen", "intents", @slug, "intent.md"])
    File.mkdir_p!(Path.dirname(intent_path))
    File.write!(intent_path, @intent_bytes)

    branch = repo |> git(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    {repo, branch, home, Kogen.Kernel.workspace_root(repo, home)}
  end

  defp approval(repo, branch) do
    base = repo |> git(["rev-parse", "HEAD"]) |> String.trim()

    %Approval{
      slug: @slug,
      intent_bytes: @intent_bytes,
      intent_sha256: :sha256 |> :crypto.hash(@intent_bytes) |> Base.encode16(case: :lower),
      target_branch: branch,
      base_sha: base,
      domains: ["queue"],
      acceptance_files: %{},
      protected_manifest: %{},
      by: "acceptance test",
      at: ~U[2026-10-03 00:00:00Z]
    }
  end

  defp write_queue_pid!(state_root, pid) do
    File.mkdir_p!(state_root)
    File.write!(Path.join(state_root, "queue.pid"), "#{pid}\n")
  end

  defp set_owner_pid(run, pid) do
    path = Path.join(run.dir, "run.json")
    contents = path |> File.read!() |> :json.decode() |> Map.put("owner_os_pid", pid)
    File.write!(path, :json.encode(contents))
  end

  defp claim_sha(repo) do
    repo |> git(["for-each-ref", "--format=%(objectname)", "refs/kogen/claim"]) |> String.trim()
  end

  defp git(repo, args), do: Git.git!(repo, args)

  defp cli(args, repo, home) do
    Proc.cmd!(
      "elixir",
      child_args() ++ ["-e", "Kogen.Kernel.CLI.main(#{inspect(args)})"],
      cd: repo,
      env: [{"HOME", home}]
    )
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
