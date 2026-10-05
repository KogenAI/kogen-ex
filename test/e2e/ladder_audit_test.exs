defmodule Kogen.E2e.LadderAuditTest do
  use Kogen.Testkit.Case

  import Kogen.E2e.Ladder,
    only: [
      done: 0,
      events: 2,
      shell: 1,
      source_at: 2,
      stage_events: 2,
      user_text: 1,
      write: 2,
      write: 3
    ]

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.Ladder
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Temp

  @moduletag :e2e
  @moduletag timeout: 300_000

  @plan "Difficulty: normal\n## Acceptance criteria\n1. TinyApp.value/0 returns :ready."
  @upheld ~s({"items":[{"id":"A1","verdict":"valid","reason":"The Request asks for :ready."}]})

  setup_all do
    root = Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, seed: Build.prepare_seed!(root, project_config: Ladder.tests_project())}
  end

  # The shape of benchmark task elx-12 A5: the shaped test asserts a bare entry is in a list
  # the Request says holds {entry, message} tuples, so no correct implementation passes it.
  test "the auditor demotes a contradicting acceptance test and the Candidate lands", context do
    seed =
      Build.prepare_seed!(Path.join(context.tmp_dir, "deprecations-seed"),
        project_config: Ladder.tests_project(),
        intent: deprecations_intent(),
        acceptance: deprecations_acceptance()
      )

    verdict =
      ~s({"items":[{"id":"A1","verdict":"contradicts","reason":"The Request lists {{:run, 3}, message} tuples, never bare {:run, 3}."}]})

    implementation = """
    defmodule TinyApp do
      # revision: base
      def value, do: :base
      def deprecated, do: [{{:run, 3}, "Use TinyApp.run/2 instead"}]
    end
    """

    script = [
      ScriptedProvider.answer(:plan, @plan),
      shell("cat > lib/tiny_app.ex <<'EOF'\n#{implementation}EOF"),
      done(),
      ScriptedProvider.answer(:audit, verdict)
    ]

    result = run!(context, "demote", script, seed)

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result

    assert source_at(result, sha) =~
             ~s(def deprecated, do: [{{:run, 3}, "Use TinyApp.run/2 instead"}])

    auditor = Enum.find(result.provider_requests, &(user_text(&1) =~ "Failing acceptance items"))
    assert {auditor.model, auditor.effort, auditor.tools} == {"gpt-6.1-sol", "high", []}
    text = user_text(auditor)
    assert text =~ "Failing acceptance items: A1"

    assert text =~
             "Request (verbatim):\nList deprecated functions as {{name, arity}, message} tuples"

    assert text =~ "assert {:run, 3} in TinyApp.deprecated()"
    assert text =~ "Failure output from the Candidate's checks:"
    assert text =~ "Use TinyApp.run/2 instead"

    assert [demoted] = events(result, "acceptance_demoted")
    assert {demoted.item, demoted.verdict} == {"A1", "contradicts"}
    assert demoted.reason =~ "never bare {:run, 3}"
    assert [%{model: "gpt-6.1-sol", effort: "high"}] = stage_events(result, "audit")

    assert {:ok, report} = Build.report(result)

    assert %{"acceptance_demoted" => [%{"item" => "A1", "verdict" => "contradicts"}]} =
             :json.decode(report)
  end

  test "a valid acceptance test is not demoted; the Candidate is repaired", context do
    script = [
      ScriptedProvider.answer(:plan, @plan),
      write("builder", :wrong),
      done(),
      ScriptedProvider.answer(:audit, @upheld),
      write("repaired", :ready),
      done()
    ]

    result = run!(context, "uphold", script)

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: repaired"
    assert events(result, "acceptance_demoted") == []
    assert [%{item: "A1", verdict: "valid"}] = events(result, "acceptance_upheld")
    assert [%{reason: "done_gate_red"}] = events(result, "repair")
  end

  test "repairs continue while failures strictly fall and stop when they do not", context do
    root = Path.join(context.tmp_dir, "markers-seed")

    seed =
      Build.prepare_seed!(root,
        project_config: markers_project(),
        extra_files: %{"bin/no-marker" => marker_script()}
      )

    script = [
      ScriptedProvider.answer(:plan, @plan),
      write("builder", :ready, ~w(m1 m2 m3 m4 m5)),
      done(),
      write("builder-2", :ready, ~w(m1 m2 m3 m4)),
      done(),
      write("builder-3", :ready, ~w(m1 m2 m3)),
      done(),
      write("builder-4", :ready, ~w(m1 m2)),
      done(),
      write("builder-5", :ready, ~w(m1)),
      done(),
      write("builder-6", :ready, ~w(m2)),
      done(),
      write("sol-medium", :ready),
      done()
    ]

    result = run!(context, "progress", script, seed)

    assert %Result{build: %{status: :landed, landed_sha: sha}} = result
    assert source_at(result, sha) =~ "# revision: sol-medium"

    repairs = events(result, "repair")
    assert length(repairs) == 5

    assert Enum.map(repairs, & &1.detail["progress"]["failure_count"]) == [5, 4, 3, 2, 1]

    assert [%{trigger: "no_progress", attempt: "sol-medium"}] =
             events(result, "escalation_started")
  end

  defp run!(context, name, script, seed \\ nil),
    do: Ladder.run!(context.tmp_dir, name, script, seed || context.seed)

  defp deprecations_intent do
    """
    ---
    title: "List deprecated functions"
    domains: [kernel]
    size: small
    ---
    Add TinyApp.deprecated/0 listing deprecated functions with their replacement hints.

    ## Acceptance
    - A1: TinyApp.deprecated/0 lists run/3 as deprecated.

    ## Verify
    - A1: test

    ## Notes
    Keep the implementation inside lib/tiny_app.ex.

    ## Request
    List deprecated functions as {{name, arity}, message} tuples from TinyApp.deprecated/0:
    run/3 is deprecated with the message "Use TinyApp.run/2 instead".
    """
  end

  defp deprecations_acceptance do
    """
    defmodule TinyApp.AcceptanceTest do
      use ExUnit.Case, async: true

      @tag intent: "build-engine/A1"
      test "lists run/3 as deprecated" do
        assert {:run, 3} in TinyApp.deprecated()
      end
    end
    """
  end

  defp markers_project do
    checks =
      Enum.map_join(~w(m1 m2 m3 m4 m5), fn marker ->
        """
          - name: no-#{marker}
            argv: [/bin/sh, bin/no-marker, #{marker}]
            timeout_ms: 60000
        """
      end)

    "name: tiny_app\nchecks:\n" <> checks <> "fix: []\ndomains:\n  kernel: [lib]\n"
  end

  defp marker_script, do: "! grep -qx \"  # $1\" lib/tiny_app.ex\n"
end
