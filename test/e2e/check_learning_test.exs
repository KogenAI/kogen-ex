defmodule Kogen.E2e.CheckLearningTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Kernel.CLI.StatusOutput
  alias Kogen.Queue.BuildSummary

  @moduletag :e2e
  @moduletag timeout: 300_000

  test "recurring review failures draft a candidate check while the approved Build completes", %{
    tmp_dir: root
  } do
    seed = Build.prepare_seed!(root)

    revise =
      ~s({"verdict":"revise","findings":["quality: A1 public API returns an unchecked result"]})

    steps = [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the target."),
      ScriptedProvider.answer(:plan, "Implement the approved ready value."),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("first")),
      ScriptedProvider.finish(),
      ScriptedProvider.answer(:review, revise),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("second")),
      ScriptedProvider.finish(),
      ScriptedProvider.answer(:review, revise),
      ScriptedProvider.write(:develop, "lib/tiny_app.ex", source("third")),
      ScriptedProvider.finish(),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]

    result = Build.run!(root, steps, %Options{seed_project: seed, builder_model: "gpt-6-luna"})
    assert result.build.status == :landed
    assert result.claim_released
    [event] = Enum.filter(result.events, &(&1.event == "check_proposal_drafted"))
    proposal = JSON.decode!(File.read!(event.path))
    assert proposal["target"] == "kogen_credo"
    assert proposal["blocking"] == false
    assert length(proposal["observations"]) == 2
    assert {:ok, summary} = BuildSummary.latest(result.fixture.workspace_root, "build-engine")
    assert StatusOutput.build_text(summary) =~ "candidate checks (caller approval required)"
    assert {:ok, report} = Build.report(result)
    assert JSON.decode!(report)["check_proposals"] == [event.path]
  end

  defp source(revision),
    do: "defmodule TinyApp do\n  # revision: #{revision}\n  def value, do: :ready\nend\n"
end
