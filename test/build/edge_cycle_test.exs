defmodule Kogen.Build.EdgeCycleTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Cycle
  alias Kogen.Build.Recipe

  @recipe Recipe.for_build("ladder", "gpt-6-luna", "max")

  test "with edge tests on, a green Candidate meets the edge probe before it is committed" do
    recipe = Recipe.for_build("ladder-luna+edge", "configured-builder", "low")
    assert Recipe.name(recipe) == "ladder-luna"
    assert Recipe.edge_tests?(recipe)
    assert %{edge_ms: 180_000} = Recipe.ladder(recipe)
    refute Recipe.edge_tests?(@recipe)
    refute Recipe.edge_tests?(Recipe.for_build("plan-shell+edge", "m", "e"))

    state = Cycle.new(%{approval: :approval, repairs: 2, recipe: recipe})
    {state, [{:run, :plan, _args}]} = Cycle.step(state, :start)
    {state, _effects} = Cycle.step(state, {:stage_ok, :plan, %{}})
    state = develop(state)

    {state, [_record, {:run, :fix, _args}]} =
      Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :done}})

    {state, [_record, {:run, :check, _args}]} = Cycle.step(state, {:stage_ok, :fix, %{}})

    {state, [{:record, %{event: :stage_ok}}, {:edge, %{}}]} =
      Cycle.step(state, {:stage_ok, :check, %{}})

    assert state.stage == :edge

    {state, [{:run, :commit, %{attempt: "builder-edge", findings: []}}]} =
      Cycle.step(state, {:edge_done, "builder-edge"})

    assert {state.stage, state.attempt} == {:commit, "builder-edge"}
  end

  defp develop(state) do
    {state, [{:record, %{event: :stage_ok}}]} =
      Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-0"}})

    state
  end
end
