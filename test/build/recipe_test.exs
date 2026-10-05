defmodule Kogen.Build.RecipeTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Recipe

  test "staged pins the context, planner, and reviewer while model flags select the builder" do
    recipe = Recipe.for_build("staged", "custom-builder", "medium")

    assert recipe.roles == %{
             context: {"gpt-6-luna", "low"},
             planner: {"gpt-6.1-sol", "high"},
             builder: {"custom-builder", "medium"},
             reviewer: {"gpt-6.1-sol", "high"}
           }

    assert Recipe.role_settings(recipe) == %{
             context: %{model: "gpt-6-luna", effort: "low"},
             planner: %{model: "gpt-6.1-sol", effort: "high"},
             builder: %{model: "custom-builder", effort: "medium"},
             reviewer: %{model: "gpt-6.1-sol", effort: "high"}
           }
  end

  test "direct recipes only record the builder role" do
    assert Recipe.for_build("direct", "builder", "low").roles == %{
             builder: {"builder", "low"}
           }

    assert Recipe.for_build("direct-shell", "builder", "low").roles == %{
             builder: {"builder", "low"}
           }

    recipe = Recipe.for_build("direct-escalate", "gpt-6-luna", "max")
    assert recipe.stages == [:develop, :done_gate, :fix, :check, :commit, :land]
    assert recipe.roles == %{builder: {"gpt-6-luna", "max"}}

    assert recipe.escalation == %{
             model: "gpt-6.1-sol",
             effort: "high",
             on: [:repair_cap, :unchanged, :gate_red, :turn_cap, :wall_cap]
           }
  end

  test "plan-shell and escalate-shell define shell-only builder recipes" do
    plan_shell = Recipe.for_build("plan-shell", "gpt-6-luna", "max")

    assert plan_shell.stages == [:plan, :develop, :done_gate, :fix, :check, :commit, :land]
    assert plan_shell.builder_tools == :shell

    assert plan_shell.roles == %{
             planner: {"gpt-6.1-sol", "high"},
             builder: {"gpt-6-luna", "max"}
           }

    refute Map.has_key?(plan_shell.roles, :context)
    refute Map.has_key?(plan_shell.roles, :reviewer)

    escalate_shell = Recipe.for_build("escalate-shell", "gpt-6-luna", "max")

    assert escalate_shell.stages == [:develop, :done_gate, :fix, :check, :commit, :land]
    assert escalate_shell.builder_tools == :shell
    assert escalate_shell.roles == %{builder: {"gpt-6-luna", "max"}}

    assert escalate_shell.escalation == %{
             model: "gpt-6.1-sol",
             effort: "high",
             on: [:repair_cap, :unchanged, :gate_red, :turn_cap, :wall_cap]
           }
  end
end
