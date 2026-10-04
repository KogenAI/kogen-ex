defmodule Kogen.Acceptance.FlakePolicyTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Cycle
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure

  @moduletag :acceptance

  @tag intent: "flake-policy/A1"
  test "an unchanged candidate after a red done gate fails as unchanged" do
    state = started()
    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red}})
    assert state.stage == :develop

    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})

    assert {:failed, :unchanged} = state.result
  end

  @tag intent: "flake-policy/A2"
  test "repeated red gates still stop at the repair cap" do
    state = started()
    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-2"}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-3"}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red}})

    assert {:failed, :repair_cap} = state.result
  end

  @tag intent: "flake-policy/A3"
  test "an unchanged candidate after a red check still fails as unchanged" do
    state = started()
    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :done}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :fix, %{}})

    failure = %Failure{class: :candidate, reason: :red, detail: "tail"}
    {state, _effects} = Cycle.step(state, {:stage_failed, :check, failure})
    {state, _effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})

    assert {:failed, :unchanged} = state.result
  end

  defp started do
    state =
      Cycle.new(%{
        approval: %{slug: "probe"},
        repairs: 2,
        recipe: Recipe.for_build("staged", "scripted-model", "medium")
      })

    {state, _effects} = Cycle.step(state, :start)
    {state, _effects} = Cycle.step(state, {:stage_ok, :context, %{}})
    {state, _effects} = Cycle.step(state, {:stage_ok, :plan, %{}})
    state
  end
end
