defmodule Kogen.E2e.DirectEscalationTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @moduletag timeout: 300_000

  test "failed Build report includes last gate findings and stop counts", context do
    seed_project =
      Build.prepare_seed!(Path.join(context.tmp_dir, "failed-report-seed"),
        project_config: gate_project()
      )

    parent = Path.join(context.tmp_dir, "failed-report")
    File.mkdir_p!(parent)

    script = [
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("luna", :wrong)),
      ScriptedProvider.finish(),
      ScriptedProvider.finish()
    ]

    result =
      Build.run!(parent, script, %Options{seed_project: seed_project, recipe: "direct"})

    assert result.build.status == :failed
    assert result.build.reason == :unchanged
    candidate_diff = Path.join(result.build.run_dir, "candidate.diff")
    assert File.regular?(candidate_diff)
    diff = File.read!(candidate_diff)
    assert diff =~ "lib/tiny_app.ex"
    assert diff =~ "revision: luna"
    refute diff =~ "test/acceptance/build-engine_test.exs"
    assert {:ok, report} = Build.report(result)

    decoded = :json.decode(report)

    assert %{
             "last_gate" => %{"status" => "fail", "checks" => checks, "findings" => findings}
           } = decoded

    assert Enum.any?(checks, &(&1["name"] == "tests" and &1["exit_level"] == 1))

    assert %{
             "candidate_diffs" => [snapshot],
             "red_checks" => red_checks,
             "acceptance_items" => acceptance_items
           } = decoded

    assert snapshot["attempt"] == "builder"
    assert snapshot["file"] == "candidate.diff"
    assert Path.basename(snapshot["source_path"]) == "candidate.diff"
    assert File.read!(snapshot["source_path"]) == diff
    assert Enum.any?(red_checks, &(&1["name"] == "tests" and &1["exit_level"] == 1))
    assert Enum.any?(acceptance_items, &(&1["id"] == "A1" and &1["text"] =~ "returns :ready"))

    assert Enum.any?(findings, fn finding ->
             is_binary(finding["path"]) and String.ends_with?(finding["path"], "_test.exs") and
               is_integer(finding["line"]) and
               finding["location"] == "#{finding["path"]}:#{finding["line"]}" and
               is_binary(finding["message"]) and finding["message"] != ""
           end)

    assert %{
             "stop" => %{
               "reason" => "unchanged",
               "reason_text" => "unchanged",
               "attempt" => "builder",
               "repair_cap" => 2,
               "repairs_used" => 1,
               "repairs_remaining" => 1,
               "failed_test_count" => 1,
               "check_count" => 1,
               "failed_check_count" => 1
             }
           } = decoded
  end

  test "failed escalation preserves a separate red candidate diff for each attempt", context do
    seed_project =
      Build.prepare_seed!(Path.join(context.tmp_dir, "failed-escalation-seed"),
        project_config: gate_project()
      )

    parent = Path.join(context.tmp_dir, "failed-escalation")
    File.mkdir_p!(parent)

    script = [
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("luna", :wrong)),
      ScriptedProvider.finish(),
      ScriptedProvider.finish(),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("sol", :still_wrong)),
      ScriptedProvider.finish(),
      ScriptedProvider.finish()
    ]

    result =
      Build.run!(parent, script, %Options{
        seed_project: seed_project,
        recipe: "direct-escalate"
      })

    assert result.build.status == :failed
    assert result.build.reason == :unchanged

    builder_diff = Path.join(result.build.run_dir, "candidate.diff")
    escalation_diff = Path.join(result.build.run_dir, "candidate-escalation.diff")
    assert File.read!(builder_diff) =~ "revision: luna"
    assert File.read!(escalation_diff) =~ "revision: sol"
    refute File.read!(escalation_diff) =~ "revision: luna"

    assert {:ok, report} = Build.report(result)
    assert %{"candidate_diffs" => [builder, escalation]} = :json.decode(report)
    assert builder["attempt"] == "builder"
    assert builder["file"] == "candidate.diff"
    assert escalation["attempt"] == "escalation"
    assert escalation["file"] == "candidate-escalation.diff"
    assert escalation["red_checks"] != []
    assert escalation["acceptance_items"] != []
  end

  test "retries a red Luna candidate from a fresh base tree", context do
    seed_project =
      Build.prepare_seed!(Path.join(context.tmp_dir, "seed"), project_config: gate_project())

    parent = Path.join(context.tmp_dir, "direct-escalate")
    File.mkdir_p!(parent)

    script = [
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("luna", :wrong)),
      ScriptedProvider.finish(),
      ScriptedProvider.finish(),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("sol", :ready)),
      ScriptedProvider.finish()
    ]

    result =
      Build.run!(parent, script, %Options{
        seed_project: seed_project,
        recipe: "direct-escalate",
        builder_model: "gpt-6-luna",
        builder_effort: "max"
      })

    assert %Result{build: %{status: :landed, landed_sha: sha}, run_status: :landed} = result

    assert Enum.map(result.provider_requests, & &1.model) ==
             List.duplicate("gpt-6-luna", 3) ++ List.duplicate("gpt-6.1-sol", 2)

    [escalation] = Enum.filter(result.events, &(&1.event == "escalation_started"))
    assert escalation.trigger == "unchanged"
    assert escalation.attempt == "escalation"
    assert escalation.summary =~ "Last deterministic gate findings"
    refute escalation.findings == []

    escalation_request = Enum.find(result.provider_requests, &(&1.model == "gpt-6.1-sol"))
    assert escalation_request

    escalation_input =
      escalation_request.input
      |> Enum.flat_map(&Map.get(&1, "content", []))
      |> Enum.map_join("\n", &Map.get(&1, "text", ""))

    assert escalation_input =~ "Approved Intent:"
    assert escalation_input =~ escalation.summary
    refute escalation_input =~ "# revision: luna"

    model_stages = Enum.filter(result.events, &(&1.event == "model_stage"))
    assert Enum.map(model_stages, & &1.attempt) == ["builder", "builder", "escalation"]
    assert Enum.map(model_stages, & &1.model) == ["gpt-6-luna", "gpt-6-luna", "gpt-6.1-sol"]
    assert Enum.all?(model_stages, &is_integer(&1.wall_ms))

    landed = Git.git!(result.fixture.origin, ["show", "#{sha}:lib/tiny_app.ex"])
    assert landed =~ "# revision: sol"
    assert landed =~ "def value, do: :ready"
    refute landed =~ "# revision: luna"

    assert {:ok, report} = Build.report(result)
    assert %{"attempts" => [builder, escalated]} = :json.decode(report)
    assert builder["attempt"] == "builder"
    assert builder["model"] == "gpt-6-luna"
    assert builder["status"] == "failed"
    assert is_integer(builder["wall_ms"])
    assert builder["tokens"]["input"] == 0
    assert escalated["attempt"] == "escalation"
    assert escalated["model"] == "gpt-6.1-sol"
    assert escalated["status"] == "landed"
    assert is_integer(escalated["wall_ms"])
    assert escalated["tokens"]["input"] == 0
  end

  test "escalate-shell keeps shell-only tools in Luna and Sol attempts", context do
    seed_project =
      Build.prepare_seed!(Path.join(context.tmp_dir, "shell-seed"),
        project_config: gate_project()
      )

    parent = Path.join(context.tmp_dir, "escalate-shell")
    File.mkdir_p!(parent)

    script = [
      shell_edit("luna", :wrong),
      ScriptedProvider.finish(),
      ScriptedProvider.finish(),
      shell_edit("sol", :ready),
      ScriptedProvider.finish()
    ]

    result =
      Build.run!(parent, script, %Options{
        seed_project: seed_project,
        recipe: "escalate-shell",
        builder_model: "gpt-6-luna",
        builder_effort: "max"
      })

    assert %Result{build: %{status: :landed, landed_sha: sha}, run_status: :landed} = result

    assert Enum.map(result.provider_requests, & &1.model) ==
             List.duplicate("gpt-6-luna", 3) ++ List.duplicate("gpt-6.1-sol", 2)

    assert Enum.all?(
             result.provider_requests,
             &(Enum.map(&1.tools, fn tool -> tool["name"] end) ==
                 ["shell", "tool_output", "finish"])
           )

    assert [escalation] = Enum.filter(result.events, &(&1.event == "escalation_started"))
    assert escalation.attempt == "escalation"

    assert Enum.map(Enum.filter(result.events, &(&1.event == "model_stage")), & &1.attempt) == [
             "builder",
             "builder",
             "escalation"
           ]

    source = Git.git!(result.fixture.origin, ["show", "#{sha}:lib/tiny_app.ex"])
    assert source =~ "# revision: sol"
    assert source =~ "def value, do: :ready"
  end

  defp shell_edit(marker, value) do
    command = "cat > lib/tiny_app.ex <<'EOF'\n" <> source(marker, value) <> "EOF"
    ScriptedProvider.call(:develop, "shell", %{"cmd" => command})
  end

  defp source(marker, value) do
    """
    defmodule TinyApp do
      # revision: #{marker}
      def value, do: :#{value}
    end
    """
  end

  defp gate_project do
    """
    name: tiny_app
    checks:
      - name: tests
        argv: [mix, test]
        timeout_ms: 60000
    fix: []
    domains:
      kernel: [lib]
    """
  end
end
