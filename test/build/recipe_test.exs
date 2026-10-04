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
  end
end
