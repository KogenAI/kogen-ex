defmodule Kogen.Build.CycleCapTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Cycle
  alias Kogen.Build.Recipe

  test "escalate-shell escalates turn and wall caps once on a fresh attempt" do
    recipe = Recipe.for_build("escalate-shell", "gpt-6-luna", "max")

    for {outcome, reason} <- [turn_cap: :turn_cap, wall_cap: :wall_cap] do
      state = state_at(:done_gate, recipe)
      {escalation, effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: outcome}})

      assert escalation.attempt == :escalation
      assert escalation.escalation_used?

      assert [
               {:record, %{event: :escalation_started, trigger: ^reason}},
               {:escalate, %{trigger: ^reason}},
               {:run, :develop, %{attempt: :escalation}}
             ] = effects

      {escalation, _effects} =
        Cycle.step(escalation, {:stage_ok, :develop, %{tree: "fresh-escalation-tree"}})

      assert escalation.last_tree == "fresh-escalation-tree"

      {failed, effects} =
        Cycle.step(escalation, {:stage_ok, :done_gate, %{outcome: outcome}})

      assert {:failed, ^reason} = failed.result
      refute Enum.any?(effects, &match?({:escalate, _args}, &1))
    end
  end

  test "non-escalating recipes preserve explicit turn and wall cap failures" do
    recipe = Recipe.for_build("staged", "builder", "medium")

    for outcome <- [:turn_cap, :wall_cap] do
      state = state_at(:done_gate, recipe)
      {failed, effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: outcome}})

      assert {:failed, ^outcome} = failed.result

      assert [{:record, %{event: :finished, reason: ^outcome}}, {:finish, :failed, ^outcome}] =
               effects
    end
  end

  defp state_at(stage, recipe) do
    %{approval: %{slug: "sample"}, repairs: 2, recipe: recipe}
    |> Cycle.new()
    |> struct!(stage: stage)
  end
end
