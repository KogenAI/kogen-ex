defmodule Kogen.E2e.PlanShellTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @tag timeout: 120_000

  setup_all do
    seed_project = Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)
    {:ok, seed_project: seed_project}
  end

  test "one-shot ls-files planner hands its exact plan to the shell builder and lands", context do
    parent = Path.join(context.tmp_dir, "plan-shell-recipe")
    File.mkdir_p!(parent)
    shell_edit = "cat > lib/tiny_app.ex <<'EOF'\n" <> ready_source() <> "EOF"
    plan_text = "## Acceptance criteria\n\n1. TinyApp.value/0 returns :ready."

    script = [
      ScriptedProvider.answer(:plan, plan_text),
      ScriptedProvider.call(:develop, "shell", %{"cmd" => shell_edit}),
      ScriptedProvider.answer(:develop, "Done.")
    ]

    options = %Options{
      seed_project: context.seed_project,
      recipe: "plan-shell",
      builder_model: "gpt-6-luna",
      builder_effort: "max"
    }

    result = Build.run!(parent, script, options)

    assert %Result{build: %{status: :landed, landed_sha: sha}, run_status: :landed} = result
    assert [started] = Enum.filter(result.events, &(&1.event == "started"))
    assert started.recipe == "plan-shell"
    refute Map.has_key?(started.roles, "context")
    refute Map.has_key?(started.roles, "reviewer")

    [planner, builder_edit, _builder_finish] = result.provider_requests
    assert {planner.model, planner.effort} == {"gpt-6.1-sol", "high"}

    assert planner.instructions =~
             "You are a staff engineer writing a one-shot implementation plan"

    assert planner.instructions =~ "## Acceptance criteria"
    assert planner.instructions =~ "## Technical approach"
    assert planner.instructions =~ "## Implementation steps"
    assert planner.tools == []
    assert planner.previous_response_id == nil

    intent =
      File.read!(Path.join(result.fixture.project_root, ".kogen/intents/build-engine/intent.md"))

    files = Git.git!(result.fixture.project_root, ["ls-files"])

    expected_planner_input =
      "TASK (verbatim):\n```\n" <>
        intent <>
        "\n```\n\nREPOSITORY FILE LIST (git ls-files):\n```\n" <>
        files <> "```\n"

    assert user_text(planner) == expected_planner_input

    assert user_text(planner) =~
             "## Request\nPreserve this fixture wording verbatim as source context."

    refute user_text(planner) =~ "defmodule TinyApp do"

    assert length(
             Enum.filter(result.provider_requests, &(&1.instructions == planner.instructions))
           ) == 1

    assert {builder_edit.model, builder_edit.effort} == {"gpt-6-luna", "max"}
    assert Enum.map(builder_edit.tools, & &1["name"]) == ["shell"]

    builder_text = user_text(builder_edit)
    assert builder_text =~ "Approved Intent:\n#{intent}"
    assert builder_text =~ "## Request\nPreserve this fixture wording verbatim as source context."

    assert builder_text =~
             "## Implementation plan\n\nA senior engineer prepared the plan below by investigating a scratch copy of this repository"

    assert builder_text =~ "<plan>\n#{plan_text}\n</plan>\n"

    assert Enum.map(Enum.filter(result.events, &(&1.event == "model_stage")), & &1.stage) == [
             "plan",
             "develop"
           ]

    source = Git.git!(result.fixture.origin, ["show", "#{sha}:lib/tiny_app.ex"])
    assert source =~ "def value, do: :ready"
  end

  defp ready_source do
    """
    defmodule TinyApp do
      # revision: plan-shell
      def value, do: :ready
    end
    """
  end

  defp user_text(%{input: [%{"role" => "user", "content" => [%{"text" => text}]}]}), do: text
end
