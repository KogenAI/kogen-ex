defmodule Kogen.Kernel.QueueSchedulingTest do
  use Kogen.Testkit.Case

  import ExUnit.CaptureIO

  alias Kogen.Kernel.CLI.StatusOutput
  alias Kogen.Queue.Drain
  alias Kogen.Queue.Status
  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.IntentFixture

  test "dependencies gate priority and waiting priorities are reread between complete Builds", %{
    tmp_dir: root
  } do
    repo =
      seed!(root, [
        {"foundation", 0, [], true},
        {"dependent", 99, ["foundation"], true},
        {"urgent", 5, [], true},
        {"ordinary", 1, [], true},
        {"waiting", 100, ["draft"], true},
        {"draft", 0, [], false}
      ])

    before = status_text(repo, root)
    assert before =~ "Next: urgent (priority 5; no dependencies"
    assert before =~ "Blocked:"
    assert before =~ "waiting for delivered dependencies: foundation"
    assert before =~ "waiting for delivered dependencies: draft"

    output =
      capture_io(fn ->
        assert {:ok, %{builds: builds, stop: :blocked}} =
                 drain(repo, root, fn slug ->
                   if slug == "urgent" do
                     path = intent_path(repo, "foundation")

                     File.write!(
                       path,
                       String.replace(File.read!(path), "priority: 0", "priority: 20")
                     )

                     # A waiting preference does not rewrite any approved Build contract.
                     assert {:ok, approved} = State.approval(repo, "foundation", Git.env())
                     assert approved.intent_bytes =~ "priority: 0"
                   end
                 end)

        assert Enum.map(builds, & &1.slug) == ["urgent", "foundation", "dependent", "ordinary"]
      end)

    assert output =~ "selected foundation: priority 20"
    assert output =~ "selected dependent: priority 99; dependencies delivered"
    assert output =~ "blocked waiting: waiting for delivered dependencies: draft"
    assert status_text(repo, root) =~ "Blocked:"
  end

  test "cycles, invalid dependencies and unknown slugs are reported while independent work runs",
       %{tmp_dir: root} do
    repo =
      seed!(root, [
        {"cycle-a", 100, ["cycle-b"], true},
        {"cycle-b", 100, ["cycle-a"], true},
        {"unknown", 100, ["absent"], true},
        {"invalid", 100, ["../escape"], true},
        {"independent", 0, [], true}
      ])

    text = status_text(repo, root)
    assert text =~ "dependency cycle: cycle-a -> cycle-b -> cycle-a"
    assert text =~ "unknown dependencies: absent"
    assert text =~ "invalid dependencies: ../escape"
    assert text =~ "Next: independent"

    output =
      capture_io(fn ->
        assert {:ok, %{builds: [%{slug: "independent"}], stop: :blocked}} = drain(repo, root)
      end)

    refute output =~ "building cycle"
    assert output =~ "queue: blocked cycle-a: dependency cycle"
    assert output =~ "queue: blocked unknown: unknown dependencies: absent"
  end

  test "a malformed waiting priority blocks its Intent with a clear message", %{tmp_dir: root} do
    repo = seed!(root, [{"invalid-priority", 0, [], true}])
    path = intent_path(repo, "invalid-priority")
    File.write!(path, String.replace(File.read!(path), "priority: 0", "priority: high"))

    assert status_text(repo, root) =~
             "invalid scheduling metadata: frontmatter `priority` must be an integer"

    output = capture_io(fn -> assert {:ok, %{builds: [], stop: :blocked}} = drain(repo, root) end)
    refute output =~ "building invalid-priority"
  end

  defp drain(repo, root, during_build \\ fn _slug -> :ok end) do
    Drain.run(Path.join(root, "queue"), %{
      recover: fn -> {:ok, []} end,
      statuses: fn -> statuses(repo, root) end,
      say: &IO.write/1,
      build: fn slug ->
        during_build.(slug)

        Git.git!(repo, [
          "commit",
          "--quiet",
          "--allow-empty",
          "-m",
          "Deliver #{slug}\n\nKogen-Intent: #{slug}"
        ])

        sha = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()

        {:ok,
         %{
           slug: slug,
           status: :landed,
           run_id: "run-#{slug}",
           landed_sha: sha,
           class: nil,
           reason: nil
         }}
      end
    })
  end

  defp status_text(repo, root) do
    {:ok, statuses} = statuses(repo, root)
    StatusOutput.text(%{statuses: statuses, queue: :stopped}, 0)
  end

  defp statuses(repo, root),
    do: Status.list(repo, Path.join(root, "state"), repo, "main", Git.env())

  defp seed!(root, entries) do
    repo = Git.create!(Path.join(root, "project"))
    Git.git!(repo, ["branch", "-M", "main"])
    base = repo |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()

    for {slug, priority, deps, approved?} <- entries do
      bytes =
        String.replace(
          IntentFixture.source(),
          "size: small",
          "size: small\npriority: #{priority}\nblocks_on: [#{Enum.join(deps, ", ")}]"
        )

      path = intent_path(repo, slug)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)

      if approved? do
        assert {:ok, _sha} =
                 State.approve(
                   repo,
                   %Approval{
                     slug: slug,
                     intent_bytes: bytes,
                     intent_sha256: Kogen.Intent.hash(bytes),
                     target_branch: "main",
                     base_sha: base,
                     domains: ["intent"],
                     acceptance_files: %{},
                     protected_manifest: %{},
                     by: "queue test",
                     at: ~U[2026-10-03 00:00:00Z]
                   },
                   Git.env()
                 )
      end
    end

    repo
  end

  defp intent_path(repo, slug), do: Path.join([repo, ".kogen", "intents", slug, "intent.md"])
end
