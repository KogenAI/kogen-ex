defmodule Kogen.E2e.LandingRepairTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @moduletag timeout: 120_000

  setup_all do
    {:ok, seed: Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)}
  end

  test "a conflict repairs in the winning conversation and lands on the moved base", context do
    result =
      Build.run!(context.tmp_dir, script() ++ repair(), %Options{
        seed_project: context.seed,
        move_base_on: move_file("lib/tiny_app.ex", source(:foreign))
      })

    assert result.build.status == :landed
    assert result.claim_released
    assert Enum.count(result.events, &(&1.event == "repair" and &1.stage == "land")) == 1

    assert Enum.any?(
             result.events,
             &(&1.reason == "rebase_conflict" and &1.detail =~ "lib/tiny_app.ex")
           ),
           result.events
           |> Enum.filter(&(&1.event in ["repair", "stage_failure"]))
           |> Enum.map(&Map.take(&1, [:event, :reason, :detail]))
           |> inspect()

    assert Enum.count(result.events, &(&1.event == "model_stage" and &1.stage == "plan")) == 1
    assert Enum.count(result.events, &(&1.event == "model_stage" and &1.stage == "context")) == 1
    [_, _, resumed | _] = Enum.filter(result.provider_requests, &(&1.model == "scripted-model"))
    assert inspect(resumed) =~ "Rebase onto"
    assert inspect(resumed) =~ "lib/tiny_app.ex"
    assert length(resumed.input) > 2
    assert_landed_tree(result)
  end

  test "red full verification after a clean rebase becomes repair feedback", %{tmp_dir: root} do
    seed =
      Build.prepare_seed!(root,
        project_config: """
        name: tiny_app
        checks:
          - name: moved-check
            argv: [sh, -c, 'test ! -f moved.txt || test -f repaired.txt']
            timeout_ms: 60000
        fix: []
        domains:
          kernel: [lib, repaired.txt]
        """
      )

    result =
      Build.run!(
        Path.join(root, "red"),
        script() ++
          [
            ScriptedProvider.write(:develop, "repaired.txt", "fixed\n"),
            ScriptedProvider.finish(),
            ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
          ],
        %Options{seed_project: seed, move_base_on: move_file("moved.txt", "new base\n")}
      )

    assert result.build.status == :landed
    assert Enum.any?(result.events, &(&1.event == "repair" and &1.detail =~ "moved-check"))
    assert {:ok, report} = Build.report(result)
    assert Enum.any?(:json.decode(report)["failures"], &(&1["reason"] == "verification_failed"))
    assert_landed_tree(result)
  end

  test "an unrepairable conflict parks a candidate and releases its claim", context do
    result =
      Build.run!(
        context.tmp_dir,
        script() ++ [ScriptedProvider.fail(:develop, :login)],
        %Options{
          seed_project: context.seed,
          move_base_on: move_file("lib/tiny_app.ex", source(:foreign))
        }
      )

    assert result.build.status == :parked
    assert result.claim_released
    ref = "refs/kogen/parked/#{result.build.run_id}"
    assert String.trim(Git.git!(result.fixture.origin, ["rev-parse", ref])) != ""

    assert Enum.any?(
             result.build.lines,
             &String.starts_with?(
               &1,
               "parked build-engine: base_moved; best candidate red at #{ref} (Build "
             )
           )

    assert {:ok, report} = Build.report(result)

    assert %{"status" => "parked", "parked_ref" => ^ref, "candidate_verdict" => "red"} =
             :json.decode(report)
  end

  test "protected base drift during landing is retained and re-gated", %{tmp_dir: root} do
    seed =
      Build.prepare_seed!(root,
        extra_files: %{"test/support/helper.txt" => "approved\n"},
        project_config: """
        name: tiny_app
        checks:
          - name: source-present
            argv: [test, -s, lib/tiny_app.ex]
            timeout_ms: 60000
        fix: []
        protected_paths: [test/support/**]
        domains:
          kernel: [lib]
        """
      )

    result =
      Build.run!(Path.join(root, "drift"), script(), %Options{
        seed_project: seed,
        move_base_on: move_file("test/support/helper.txt", "current\n")
      })

    assert result.build.status == :landed

    assert Git.git!(result.fixture.origin, ["show", "main:test/support/helper.txt"]) ==
             "current\n"

    assert {:ok, report} = Build.report(result)
    assert Enum.any?(:json.decode(report)["findings"], &(&1["type"] == "base_drift"))
    assert_landed_tree(result)
  end

  test "losing the landing swap twice rebases and verifies each new tip", context do
    result =
      Build.run!(context.tmp_dir, script(), %Options{
        seed_project: context.seed,
        move_base_on: fn
          fixture, :review -> move_on_incoming(fixture)
          _fixture, _stage -> :skip
        end
      })

    assert result.build.status == :landed
    assert Enum.count(result.events, &(&1.event == "check_result")) == 3

    assert Enum.map(Enum.filter(result.events, &(&1.event == "landing_retry")), & &1.wall_ms) == [
             1_000,
             2_000,
             4_000,
             1_000,
             2_000,
             4_000
           ]

    assert result.claim_released
    assert_landed_tree(result)

    assert Git.git!(result.fixture.origin, [
             "for-each-ref",
             "--format=%(refname)",
             "refs/kogen/incoming"
           ]) == ""
  end

  test "acceptance tampering during landing fails only this Build", context do
    path = ".kogen/acceptance/build-engine_test.exs"
    changed = File.read!(Path.join(context.seed, path)) <> "\n# foreign edit\n"

    result =
      Build.run!(context.tmp_dir, script(), %Options{
        seed_project: context.seed,
        move_base_on: move_file(path, changed)
      })

    assert result.build.status == :failed
    assert result.build.failure.reason == :approved_acceptance_changed
    assert result.build.failure.detail =~ path
    assert result.claim_released
    refute Enum.any?(result.events, &(&1.event == "repair"))
  end

  defp move_on_incoming(fixture) do
    tips =
      Enum.map(1..2, fn index ->
        Git.git!(fixture.project_root, [
          "commit",
          "--quiet",
          "--allow-empty",
          "-m",
          "Advance base #{index}"
        ])

        String.trim(Git.git!(fixture.project_root, ["rev-parse", "HEAD"]))
      end)

    [first, second] = tips
    Git.git!(fixture.project_root, ["push", "--quiet", "origin", "HEAD:refs/kogen/test-moved"])
    hook = Path.join(fixture.origin, "hooks/post-receive")
    File.mkdir_p!(Path.dirname(hook))

    File.write!(hook, """
    #!/bin/sh
    while read old new ref; do
      case "$ref" in
        refs/kogen/incoming/*)
          current=$(git rev-parse refs/heads/main)
          case "$current" in
            #{fixture.approved_base}) git update-ref refs/heads/main #{first} "$current" ;;
            #{first}) git update-ref refs/heads/main #{second} "$current" ;;
          esac ;;
      esac
    done
    """)

    File.chmod!(hook, 0o755)
    :ok
  end

  defp move_file(path, bytes) do
    fn
      fixture, :review ->
        full = Path.join(fixture.project_root, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, bytes)
        Git.git!(fixture.project_root, ["add", "--all"])
        Git.git!(fixture.project_root, ["commit", "--quiet", "-m", "Advance base with changes"])
        Git.git!(fixture.project_root, ["push", "--quiet", "origin", "main"])
        :ok

      _fixture, _stage ->
        :skip
    end
  end

  defp assert_landed_tree(result) do
    sha = result.build.landed_sha
    origin = result.fixture.origin
    assert Git.git!(origin, ["log", "-1", "--format=%s", "#{sha}^"]) =~ "Advance base"
    tree = String.trim(Git.git!(origin, ["rev-parse", "#{sha}^{tree}"]))
    check = result.events |> Enum.filter(&(&1.event == "check_result")) |> List.last()
    assert Enum.all?(check.receipts, &(&1["tree"] == tree))
  end

  defp script do
    [
      ScriptedProvider.answer(:context, "Update TinyApp.value/0."),
      ScriptedProvider.answer(:plan, "Return ready."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source(:ready)),
      ScriptedProvider.finish(),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end

  defp repair do
    [
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source(:ready)),
      ScriptedProvider.finish(),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end

  defp source(value),
    do: "defmodule TinyApp do\n  # revision: #{value}\n  def value, do: :#{value}\nend\n"
end
