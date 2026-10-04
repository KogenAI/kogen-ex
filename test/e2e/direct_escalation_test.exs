defmodule Kogen.E2e.DirectEscalationTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @tag timeout: 120_000

  test "retries a red Luna candidate from a fresh base tree", context do
    seed_project =
      Build.prepare_seed!(Path.join(context.tmp_dir, "seed"), project_config: gate_project())

    parent = Path.join(context.tmp_dir, "direct-escalate")
    File.mkdir_p!(parent)

    script = [
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("luna", :wrong)),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("sol", :ready)),
      ScriptedProvider.answer(:develop, "Done.")
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
