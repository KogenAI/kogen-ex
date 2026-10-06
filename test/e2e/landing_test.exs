defmodule Kogen.E2e.LandingTest do
  use Kogen.Testkit.Case

  import ExUnit.CaptureIO, only: [capture_io: 2]

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @moduletag timeout: 300_000

  setup_all do
    {:ok, seed_project: Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)}
  end

  test "lands into a clean checkout of the base branch and updates it", context do
    parent = scenario_parent(context, "clean-checkout")
    options = %Options{seed_project: context.seed_project, origin_checkout: :clean}
    result = Build.run!(parent, landing_script(), options)
    origin = result.fixture.origin

    assert %Result{build: %{status: :landed, landed_sha: sha} = build, run_status: :landed} =
             result

    assert origin |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim() == sha
    assert origin |> Git.git!(["rev-parse", "HEAD"]) |> String.trim() == sha
    assert_value(origin, ":ready")
    assert Git.git!(origin, ["status", "--porcelain"]) == ""
    refute Enum.any?(build.lines, &String.contains?(&1, "warning"))
    refute Enum.any?(result.events, &(&1.event == "landing_warning"))
  end

  test "lands into a dirty checkout, leaves it untouched, and warns", context do
    parent = scenario_parent(context, "dirty-checkout")
    options = %Options{seed_project: context.seed_project, origin_checkout: :dirty}
    test_process = self()

    stderr =
      capture_io(:stderr, fn ->
        send(test_process, {:dirty_landing, Build.run!(parent, landing_script(), options)})
      end)

    assert_received {:dirty_landing, result}
    origin = result.fixture.origin
    local = File.read!(Path.join(origin, "lib/tiny_app.ex"))

    assert %Result{build: %{status: :landed, landed_sha: sha} = build, run_status: :landed} =
             result

    assert origin |> Git.git!(["rev-parse", "refs/heads/main"]) |> String.trim() == sha
    assert local =~ "# local edit"
    assert_value(origin, ":base")

    expected =
      "landed #{sha} on main; your checkout at #{canonical(origin)} has local changes and " <>
        "was not updated; run `git reset --keep #{sha}`, or merge it yourself"

    # Stderr capture is process-wide and can include concurrent shaping progress.
    warnings =
      stderr
      |> canonical()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "land: warning:"))

    assert warnings == ["land: warning: #{expected}"]
    assert ("land: warning: " <> expected) in Enum.map(build.lines, &canonical/1)
    assert [event] = Enum.filter(result.events, &(&1.event == "landing_warning"))
    assert canonical(event.detail) == expected

    assert {:ok, report} = Build.report(result)

    assert %{"findings" => [%{"type" => "landing_warning", "message" => message}]} =
             :json.decode(report)

    assert canonical(message) == expected
  end

  test "a persistent lock retries, re-verifies, and parks without a builder repair",
       context do
    parent = scenario_parent(context, "landing-failure")
    options = %Options{seed_project: context.seed_project, move_base_on: {:lock_base, :review}}
    result = Build.run!(parent, landing_script(), options)

    assert %Result{
             build: %{status: :parked, failure: failure, verdict: :green},
             run_status: :parked
           } = result

    assert %{class: :environment, reason: :landing_failed} = failure
    assert failure.detail =~ "ref_locked"
    assert retry_delays(result) == [1_000, 2_000, 4_000]
    assert Enum.count(result.events, &(&1.event == "check_result")) == 2

    assert Enum.any?(
             result.build.lines,
             &String.starts_with?(
               &1,
               "parked build-engine: landing_failed; best candidate green at refs/kogen/parked/"
             )
           )

    assert result.claim_released
    refute Enum.any?(result.events, &(&1.event == "repair"))

    assert [_develop] =
             Enum.filter(result.events, &(&1.event == "model_stage" and &1.stage == "develop"))
  end

  test "a temporary lock clears during the backoff and lands", context do
    parent = scenario_parent(context, "temporary-lock")

    result =
      Build.run!(parent, landing_script(), %Options{
        seed_project: context.seed_project,
        move_base_on: release_lock_on_retry(3)
      })

    assert result.build.status == :landed
    assert retry_delays(result) == [1_000, 2_000, 4_000]
    assert Enum.count(result.events, &(&1.event == "check_result")) == 1
    assert {:ok, report} = Build.report(result)

    assert Enum.map(:json.decode(report)["landing_retries"], & &1["delay_ms"]) == [
             1_000,
             2_000,
             4_000
           ]

    assert result.claim_released
  end

  test "a lock followed by a moved base retries and re-verifies the new tip", context do
    parent = scenario_parent(context, "lock-and-move")

    result =
      Build.run!(parent, landing_script(), %Options{
        seed_project: context.seed_project,
        move_base_on: release_lock_on_retry(1, true)
      })

    assert result.build.status == :landed
    assert retry_delays(result) == [1_000, 2_000, 4_000]
    assert Enum.count(result.events, &(&1.event == "check_result")) == 2

    assert Enum.map(Enum.filter(result.events, &(&1.event == "landing_retry")), & &1.reason) == [
             "ref_locked",
             "base_moved",
             "base_moved"
           ]

    parent =
      result.fixture.origin
      |> Git.git!(["rev-parse", "#{result.build.landed_sha}^"])
      |> String.trim()

    assert Git.git!(result.fixture.origin, ["log", "-1", "--format=%s", parent]) =~
             "Advance during lock"

    assert result.claim_released
  end

  defp assert_value(repo, expected) do
    output =
      Kogen.Testkit.Proc.cmd!(
        "elixir",
        ["-r", "lib/tiny_app.ex", "-e", "IO.inspect(TinyApp.value())"],
        cd: repo
      )

    assert String.trim(output) == expected
  end

  defp retry_delays(result),
    do: for(event <- result.events, event.event == "landing_retry", do: event.wall_ms)

  defp release_lock_on_retry(count, move? \\ false) do
    fn
      fixture, :review ->
        tip = if move?, do: prepare_moved_tip(fixture)
        lock = Path.join(fixture.origin, "refs/heads/main.lock")
        File.write!(lock, "held by test")

        {:ok, _worker} =
          Task.start(fn ->
            wait_for_retry(
              fixture.workspace_root,
              count,
              System.monotonic_time(:millisecond) + 30_000
            )

            File.rm!(lock)

            if tip,
              do:
                Git.git!(fixture.origin, [
                  "update-ref",
                  "refs/heads/main",
                  tip,
                  fixture.approved_base
                ])
          end)

        :ok

      _fixture, _stage ->
        :skip
    end
  end

  defp prepare_moved_tip(fixture) do
    Git.git!(fixture.project_root, [
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "Advance during lock"
    ])

    tip = fixture.project_root |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
    Git.git!(fixture.project_root, ["push", "--quiet", "origin", "HEAD:refs/kogen/test-moved"])
    tip
  end

  defp wait_for_retry(root, count, deadline) do
    events =
      for path <- Path.wildcard(Path.join(root, "runs/*/events.jsonl")),
          line <- String.split(File.read!(path), "\n", trim: true),
          event = :json.decode(line),
          event["event"] == "landing_retry",
          do: event

    if length(events) < count and System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        20 -> wait_for_retry(root, count, deadline)
      end
    end
  end

  defp scenario_parent(context, name) do
    parent = Path.join(context.tmp_dir, name)
    File.mkdir_p!(parent)
    parent
  end

  defp landing_script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", ready_source()),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end

  defp ready_source do
    """
    defmodule TinyApp do
      # revision: candidate
      def value, do: :ready
    end
    """
  end

  # Git and the Build report macOS temporary directories by their canonical /private path.
  defp canonical(path), do: String.replace(path, "/private/var/", "/var/")
end
