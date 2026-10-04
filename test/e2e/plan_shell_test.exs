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

  test "planner reads the repository and lands through the shell-only builder", context do
    parent = Path.join(context.tmp_dir, "plan-shell-recipe")
    File.mkdir_p!(parent)
    shell_edit = "cat > lib/tiny_app.ex <<'EOF'\n" <> ready_source() <> "EOF"

    script = [
      ScriptedProvider.call(:plan, "read", %{"path" => "lib/tiny_app.ex"}),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.call(:develop, "shell", %{"cmd" => shell_edit}),
      ScriptedProvider.answer(:develop, "Done.")
    ]

    options = %Options{seed_project: context.seed_project, recipe: "plan-shell"}
    result = Build.run!(parent, script, options)

    assert %Result{build: %{status: :landed, landed_sha: sha}, run_status: :landed} = result
    assert [started] = Enum.filter(result.events, &(&1.event == "started"))
    assert started.recipe == "plan-shell"
    refute Map.has_key?(started.roles, "context")
    refute Map.has_key?(started.roles, "reviewer")

    [planner_read, planner_finish, builder_edit, _builder_finish] = result.provider_requests
    assert {planner_read.model, planner_read.effort} == {"gpt-6.1-sol", "high"}
    assert Enum.map(planner_read.tools, & &1["name"]) == ["read", "search"]
    assert Enum.map(planner_finish.tools, & &1["name"]) == ["read", "search"]
    assert Enum.map(builder_edit.tools, & &1["name"]) == ["shell"]

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
end
