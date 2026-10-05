defmodule Kogen.Kernel.StatusTest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.Origin
  alias Kogen.Kernel.StateView
  alias Kogen.Kernel.Status
  alias Kogen.State.Event
  alias Kogen.State.Json
  alias Kogen.State.Run
  alias Kogen.Testkit.Git

  test "a live owner keeps an interrupted run building", %{tmp_dir: tmp_dir} do
    run = run_with_owner!(tmp_dir, String.to_integer(System.pid()))

    assert {:ok, false} = StateView.interrupted?(run, [%Event{event: "interrupted"}])
  end

  test "an interrupted event must be the last run event", %{tmp_dir: tmp_dir} do
    run = run_with_owner!(tmp_dir, 999_999)
    events = [%Event{event: "interrupted"}, %Event{event: "stage"}]

    assert {:ok, false} = StateView.interrupted?(run, events)
  end

  test "a base commit trailer reports landed without a run record", %{tmp_dir: tmp_dir} do
    slug = "landed-elsewhere"
    {repo, branch, sha} = landed_project!(tmp_dir, slug)

    assert {:ok, [status]} =
             Status.list(repo, Path.join(tmp_dir, "state"), repo, branch, Git.env())

    assert status.slug == slug
    assert status.status == :landed
    assert status.landed_sha == sha
    assert status.run_id == nil
  end

  test "a base commit trailer takes precedence over a stale run record", %{tmp_dir: tmp_dir} do
    slug = "landed-elsewhere"
    {repo, branch, sha} = landed_project!(tmp_dir, slug)
    state_root = Path.join(tmp_dir, "state")
    run_dir = Path.join([state_root, "runs", "stale-run"])

    run = %Run{
      id: "stale-run",
      dir: run_dir,
      slug: slug,
      intent_sha256: String.duplicate("a", 64),
      target_branch: branch,
      approval_commit: nil,
      status: :failed,
      landing: nil
    }

    {:ok, contents} = Json.encode_run(run)
    File.mkdir_p!(run_dir)
    File.write!(Path.join(run_dir, "run.json"), contents)

    assert {:ok, [status]} = Status.list(repo, state_root, repo, branch, Git.env())

    assert status.status == :landed
    assert status.landed_sha == sha
    assert status.run_id == "stale-run"
  end

  test "status reads 15 Intents in under three seconds", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    branch = repo |> Git.git!(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()

    for index <- 1..15 do
      slug = "probe-#{index}"
      intent = Path.join([repo, ".kogen", "intents", slug, "intent.md"])
      File.mkdir_p!(Path.dirname(intent))
      File.write!(intent, "Draft #{slug}\n")
    end

    started = System.monotonic_time(:microsecond)

    assert {:ok, statuses} =
             Status.list(repo, Path.join(tmp_dir, "state"), repo, branch, Git.env())

    elapsed = System.monotonic_time(:microsecond) - started

    assert length(statuses) == 15
    assert Enum.all?(statuses, &(&1.status == :draft))
    # Headroom for a loaded machine; a per-Intent git regression costs far more than this.
    assert elapsed <= 3_000_000
  end

  test "base defaults to configured base, then origin HEAD, then checkout branch", %{
    tmp_dir: tmp_dir
  } do
    project = Git.create!(Path.join(tmp_dir, "project"))
    Git.git!(project, ["branch", "-M", "checkout-branch"])
    origin = Git.bare!(Path.join(tmp_dir, "origin.git"))
    Git.git!(origin, ["symbolic-ref", "HEAD", "refs/heads/origin-branch"])

    assert {:ok, "configured"} =
             Kogen.Kernel.effective_base(nil, "configured", project, origin, Git.env())

    assert {:ok, "origin-branch"} =
             Kogen.Kernel.effective_base(nil, nil, project, origin, Git.env())

    File.write!(Path.join(origin, "HEAD"), String.duplicate("a", 40) <> "\n")

    assert {:ok, "checkout-branch"} =
             Kogen.Kernel.effective_base(nil, nil, project, origin, Git.env())
  end

  test "a GitHub origin URL resolves locally without fetching", %{tmp_dir: tmp_dir} do
    repo = Git.create!(tmp_dir)
    Git.git!(repo, ["remote", "add", "origin", "https://github.com/example/project.git"])
    Git.git!(repo, ["branch", "-M", "checkout-branch"])
    sha = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
    Git.git!(repo, ["update-ref", "refs/remotes/origin/main", sha])

    Git.git!(repo, [
      "symbolic-ref",
      "refs/remotes/origin/HEAD",
      "refs/remotes/origin/main"
    ])

    assert {:ok, ^repo} = Origin.resolve(repo, nil, Git.env())

    assert {:ok, "main"} = Kogen.Kernel.effective_base(nil, nil, repo, repo, Git.env())
  end

  defp run_with_owner!(tmp_dir, owner_pid) do
    dir = Path.join(tmp_dir, "interrupted-run")
    File.mkdir_p!(dir)

    %Run{
      id: "interrupted-run",
      dir: dir,
      slug: "interrupted-probe",
      intent_sha256: String.duplicate("a", 64),
      target_branch: "main",
      approval_commit: nil,
      status: :running,
      landing: nil,
      owner_os_pid: owner_pid
    }
  end

  defp landed_project!(tmp_dir, slug) do
    repo = Git.create!(tmp_dir)
    intent = Path.join([repo, ".kogen", "intents", slug, "intent.md"])

    File.mkdir_p!(Path.dirname(intent))
    File.write!(intent, "Intent landed by another clone.\n")
    Git.git!(repo, ["add", "--all"])

    Git.git!(repo, [
      "commit",
      "--quiet",
      "-m",
      "Landed by another clone\n\nKogen-Intent: #{slug}"
    ])

    sha = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
    branch = repo |> Git.git!(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()
    {repo, branch, sha}
  end
end
