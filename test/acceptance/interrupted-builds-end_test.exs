defmodule Kogen.Acceptance.InterruptedBuildsEndTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc

  @moduletag :acceptance
  @project_root Path.expand("../..", __DIR__)
  @dead_pid 999_999
  @run_id "0123456789abcdef0123456789abcdef"
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
  title: Interrupted probe
  domains: [kernel]
  size: small
  ---
  Report the interrupted probe.
  """

  @tag intent: "interrupted-builds-end/A1"
  test "show and status report a dead interrupted run", %{tmp_dir: tmp_dir} do
    {repo, branch, home, run} = interrupted_run(tmp_dir)

    show =
      ["build", "show", "interrupted-probe", "--origin", repo, "--base", branch]
      |> cli(
        repo,
        home
      )
      |> :json.decode()

    status =
      ["status", "--origin", repo, "--base", branch, "--json"]
      |> cli(repo, home)
      |> :json.decode()

    assert show["status"] == "interrupted"
    run_id = run.id

    assert [%{"slug" => "interrupted-probe", "status" => "interrupted", "run_id" => ^run_id}] =
             status
  end

  @tag intent: "interrupted-builds-end/A2"
  test "benchmark reconciles exit 143 before capturing its report", %{tmp_dir: tmp_dir} do
    task_dir = Path.join(tmp_dir, "task")
    out_dir = Path.join(tmp_dir, "out")
    work_dir = Git.create!(Path.join(tmp_dir, "work"))
    fake_kogen = Path.join(tmp_dir, "fake-kogen")
    calls_path = Path.join(tmp_dir, "calls.log")
    reconciled_path = Path.join(tmp_dir, "reconciled")
    home = Path.join(tmp_dir, "home")

    File.mkdir_p!(task_dir)
    File.mkdir_p!(home)
    File.write!(Path.join(task_dir, "prompt.md"), "Implement the fixture request.\n")

    File.write!(
      Path.join(task_dir, "task.json"),
      IO.iodata_to_binary(:json.encode(%{"env" => %{"TMPDIR" => tmp_dir}}))
    )

    Git.git!(work_dir, ["branch", "-M", "main"])
    File.write!(fake_kogen, fake_kogen_script(calls_path, reconciled_path))
    File.chmod!(fake_kogen, 0o755)

    script = Path.expand("../../bin/kogen-bench", __DIR__)
    assert {:ok, runtime} = Kogen.Kernel.runtime()

    assert {:ok, %ProcResult{exit_status: 143, timed_out: false}} =
             Kogen.Proc.run(["/bin/sh", script, task_dir, work_dir, out_dir],
               cd: tmp_dir,
               env: %{
                 "HOME" => home,
                 "KOGEN_BIN" => fake_kogen,
                 "KOGEN_CALLS" => calls_path,
                 "KOGEN_RECONCILED" => reconciled_path,
                 "PATH" => runtime.base_env["PATH"],
                 "TMPDIR" => tmp_dir
               },
               timeout_ms: 120_000
             )

    calls = calls_path |> File.read!() |> String.split("\n", trim: true)
    reconcile_index = Enum.find_index(calls, &(&1 == "reconcile:#{@run_id}"))
    report_index = Enum.find_index(calls, &(&1 == "build:show"))
    report = out_dir |> Path.join("report.json") |> File.read!() |> :json.decode()

    assert is_integer(reconcile_index)
    assert is_integer(report_index)
    assert reconcile_index < report_index
    assert report["status"] == "failed"
  end

  defp interrupted_run(tmp_dir) do
    slug = "interrupted-probe"
    {repo, branch} = project(tmp_dir, slug)
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    approved = approval(repo, branch, slug)
    {:ok, _approval_commit} = State.approve(repo, approved, @git_env)
    state_root = Kogen.Kernel.workspace_root(repo, home)
    {:ok, run} = State.start_run(state_root, approved)
    :ok = State.claim(repo, run.id, @git_env)
    :ok = State.record(run, %{event: :interrupted, reason: :sigterm})
    set_owner_pid(run, @dead_pid)

    {repo, branch, home, run}
  end

  defp project(tmp_dir, slug) do
    repo = Git.create!(Path.join(tmp_dir, "project"))
    project_yaml = Path.join(repo, ".kogen/project.yaml")
    File.mkdir_p!(Path.dirname(project_yaml))
    File.cp!(Path.join(@project_root, ".kogen/project.yaml"), project_yaml)

    intent_path = Path.join([repo, ".kogen", "intents", slug, "intent.md"])
    File.mkdir_p!(Path.dirname(intent_path))
    File.write!(intent_path, @intent_bytes)

    branch = repo |> git(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()
    {repo, branch}
  end

  defp approval(repo, branch, slug) do
    base = repo |> git(["rev-parse", "HEAD"]) |> String.trim()

    %Approval{
      slug: slug,
      intent_bytes: @intent_bytes,
      intent_sha256: :sha256 |> :crypto.hash(@intent_bytes) |> Base.encode16(case: :lower),
      target_branch: branch,
      base_sha: base,
      domains: ["kernel"],
      acceptance_files: %{},
      protected_manifest: %{},
      by: "acceptance test",
      at: ~U[2026-10-03 00:00:00Z]
    }
  end

  defp set_owner_pid(run, pid) do
    path = Path.join(run.dir, "run.json")
    contents = path |> File.read!() |> :json.decode() |> Map.put("owner_os_pid", pid)
    File.write!(path, :json.encode(contents))
  end

  defp fake_kogen_script(calls_path, reconciled_path) do
    """
    #!/bin/sh
    set -eu
    printf '%s:%s\\n' "$1" "${2:-}" >> "$KOGEN_CALLS"
    case "$1:${2:-}" in
      intent:shape)
        printf '%s\\n' '{"slug":"task","usage":[]}'
        ;;
      intent:approve)
        exit 0
        ;;
      build:show)
        if [ -f "$KOGEN_RECONCILED" ]; then
          printf '%s\\n' '{"status":"failed","candidate_diffs":[]}'
        else
          printf '%s\\n' '{"status":"building","candidate_diffs":[]}'
        fi
        ;;
      build:*)
        printf '%s\\n' 'run: #{@run_id}'
        exit 143
        ;;
      reconcile:#{@run_id})
        touch "$KOGEN_RECONCILED"
        ;;
      *)
        exit 2
        ;;
    esac
    """
    |> String.replace("$KOGEN_CALLS", calls_path)
    |> String.replace("$KOGEN_RECONCILED", reconciled_path)
  end

  defp git(repo, args), do: Proc.cmd!("git", ["-C", repo | args], env: Map.to_list(@git_env))

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
