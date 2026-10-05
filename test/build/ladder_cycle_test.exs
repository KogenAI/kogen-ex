defmodule Kogen.Build.LadderCycleTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Cycle
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure

  @recipe Recipe.for_build("ladder", "gpt-6-luna", "max")

  test "the ladder recipe is plain data with four rungs and a Sol auditor" do
    assert Recipe.stages(@recipe) == [:plan, :develop, :done_gate, :fix, :check, :commit, :land]
    assert @recipe.builder_tools == :shell
    assert Recipe.auditor(@recipe) == {"gpt-6.1-sol", "high"}

    assert %{
             rungs: rungs,
             parallel_on_hard: 2,
             repair_cap: 6,
             wall_ms: 3_600_000,
             repeat_from: 2
           } = Recipe.ladder(@recipe)

    assert Enum.map(rungs, &{&1.name, Recipe.rung_builder(@recipe, &1), &1.input}) == [
             {"builder", {"gpt-6-luna", "max"}, :plan},
             {"sol-medium", {"gpt-6.1-sol", "medium"}, :plan},
             {"sol-high", {"gpt-6.1-sol", "high"}, :plan},
             {"raw-request", {"gpt-6.1-sol", "high"}, :raw_request}
           ]

    assert Recipe.ladder(Recipe.with_wall_ms(@recipe, 60_000)).wall_ms == 60_000

    assert Recipe.with_wall_ms(Recipe.for_build("plan-shell", "m", "e"), 60_000).name ==
             "plan-shell"
  end

  test "single-model ladder variants keep every model call on one model" do
    for {name, model} <- [
          {"ladder-luna", {"gpt-6-luna", "max"}},
          {"ladder-sol-medium", {"gpt-6.1-sol", "medium"}}
        ] do
      recipe = Recipe.for_build(name, "configured-builder", "low")
      %{rungs: rungs, parallel_on_hard: 2, repair_cap: 6} = Recipe.ladder(recipe)

      assert Enum.map(rungs, &{&1.name, Recipe.rung_builder(recipe, &1), &1.input}) == [
               {"builder", model, :plan},
               {"fresh-2", model, :plan},
               {"fresh-3", model, :plan},
               {"raw-request", model, :raw_request}
             ]

      assert Recipe.role(recipe, :planner) == model
      assert Recipe.auditor(recipe) == model
      assert Recipe.stages(recipe) == Recipe.stages(@recipe)
      assert recipe.builder_tools == :shell
    end
  end

  test "ladder Builds steer environment and controller signals instead of stopping" do
    {state, _effects} = Cycle.step(start(new()), {:stage_ok, :plan, %{}})
    unusable = %Failure{class: :environment, reason: :check_unavailable, detail: "no output"}

    {repaired, effects} = Cycle.step(state, {:stage_failed, :develop, unusable})

    assert [{:record, %{event: :repair, reason: :check_unavailable}}, {:run, :develop, _}] =
             effects

    restores = %Failure{class: :controller, reason: :protected_restore_limit, detail: "tests"}
    {next, effects} = Cycle.step(repaired, {:stage_failed, :develop, restores})
    assert next.attempt == "sol-medium"
    assert [_record, {:escalate, %{trigger: :controller}}, _run] = effects

    login = %Failure{class: :environment, reason: :login, detail: "signed out"}
    {stopped, _effects} = Cycle.step(next, {:stage_failed, :develop, login})
    assert stopped.result == {:failed, {:environment, :login}}

    plan_shell =
      Cycle.new(%{approval: :a, repairs: 2, recipe: Recipe.for_build("plan-shell", "m", "e")})

    {legacy, _effects} =
      Cycle.step(%{plan_shell | stage: :develop}, {:stage_failed, :develop, unusable})

    assert legacy.result == {:failed, {:environment, :check_unavailable}}
  end

  test "each stopped rung moves to a fresh next rung with earlier rungs' findings" do
    state = developing(new())

    {state, effects} = red_gate(state, 3, ["first finding"])
    assert [{:record, %{event: :repair}}, {:run, :develop, _args}] = effects
    {state, effects} = red_gate(develop(state, "tree-2"), 3, ["first finding again"])

    assert state.attempt == "sol-medium"
    assert state.rung == 1
    assert state.repairs_left == 6

    assert [
             {:record, %{event: :escalation_started} = started},
             {:escalate, data},
             {:run, :develop, %{escalation_summary: summary, attempt: "sol-medium"}}
           ] = effects

    assert started.previous_attempt == :builder
    assert data.trigger == :no_progress
    assert {data.model, data.effort, data.input} == {"gpt-6.1-sol", "medium", :plan}
    assert summary =~ "The builder attempt stopped after no_progress."
    assert summary =~ "first finding again"
    assert summary =~ "Their diffs are not shown"

    {state, _effects} = Cycle.step(develop(state, "tree-3"), done_gate(:turn_cap))
    assert {state.attempt, state.rung} == {"sol-high", 2}

    {state, effects} = Cycle.step(develop(state, "tree-4"), done_gate(:wall_cap))
    assert {state.attempt, state.rung} == {"raw-request", 3}
    assert [_record, {:escalate, %{input: :raw_request, summary: summary}}, _run] = effects
    assert summary =~ "The sol-medium attempt stopped after turn_cap."
    assert summary =~ "The sol-high attempt stopped after wall_cap."

    # After the last rung the Build keeps making fresh attempts on the strongest rungs.
    {state, effects} = Cycle.step(develop(state, "tree-5"), done_gate(:turn_cap))
    assert {state.attempt, state.rung, state.result} == {"sol-high-2", 4, nil}

    assert [_record, {:escalate, %{model: "gpt-6.1-sol", effort: "high", input: :plan}}, _] =
             effects

    {state, _effects} = Cycle.step(develop(state, "tree-6"), done_gate(:turn_cap))
    assert state.attempt == "raw-request-2"
    {state, _effects} = Cycle.step(develop(state, "tree-7"), done_gate(:turn_cap))
    assert state.attempt == "sol-high-3"
  end

  test "a ladder without repeats ends after its last rung" do
    recipe = Map.update!(@recipe, :ladder, &%{&1 | repeat_from: nil})
    state = Cycle.new(%{approval: :approval, repairs: 2, recipe: recipe})
    state = %{developing(state) | rung: 3, attempt: "raw-request"}

    {state, effects} = Cycle.step(state, done_gate(:turn_cap))
    assert state.result == {:failed, :turn_cap}

    assert [{:record, %{event: :finished, attempt: "raw-request"}}, {:finish, :failed, _}] =
             effects
  end

  test "repairs continue while failures strictly fall, up to six per rung" do
    state = developing(new())

    {state, repairs} =
      Enum.reduce(6..1//-1, {state, 0}, fn count, {current, granted} ->
        {next, effects} = red_gate(current, count, ["#{count} failing"])
        assert [{:record, %{event: :repair, detail: detail}}, _run] = effects
        assert detail.progress.failure_count == count
        {develop(next, "tree-#{count}"), granted + 1}
      end)

    assert repairs == 6
    assert state.repairs_left == 0
    {state, _effects} = red_gate(state, 0, ["still red"])
    assert state.attempt == "sol-medium"
  end

  test "an unchanged repair or provider stop moves to the next rung" do
    state = developing(new())
    {state, _effects} = red_gate(state, 2, ["red"])
    {state, effects} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-0"}})
    assert state.attempt == "sol-medium"
    assert [_record, {:escalate, %{trigger: :unchanged}}, _run] = effects

    {state, effects} =
      Cycle.step(
        state,
        {:stage_failed, :develop, %Failure{class: :provider, reason: :timeout, detail: "hung"}}
      )

    assert state.attempt == "sol-high"
    assert [_record, {:escalate, %{trigger: :provider_failed}}, _run] = effects
  end

  test "a hard plan runs the first two rungs in parallel and commits a green winner" do
    {state, effects} = Cycle.step(start(new()), {:stage_ok, :plan, %{difficulty: :hard}})

    assert state.stage == :parallel

    assert [
             {:record, %{event: :stage_ok, stage: :plan}},
             {:record, %{event: :parallel_started, attempts: [:builder, "sol-medium"]}},
             {:parallel, %{members: [%{index: 0}, %{index: 1, rung: %{name: "sol-medium"}}]}}
           ] = effects

    outcomes = [
      outcome(0, :builder, :failed, %{checks_green: true, failing_acceptance: 1}),
      outcome(1, "sol-medium", :green, %{diff_lines: 40})
    ]

    {state, effects} = Cycle.step(state, {:parallel_done, outcomes})
    assert {state.stage, state.attempt} == {:commit, "sol-medium"}

    assert [
             {:record, %{event: :parallel_selected, attempt: "sol-medium", result: :green}},
             {:adopt, "sol-medium"},
             {:run, :commit, %{findings: []}}
           ] = effects
  end

  test "red parallel rungs continue the ladder from the better one" do
    {state, _effects} = Cycle.step(start(new()), {:stage_ok, :plan, %{difficulty: :hard}})

    outcomes = [
      outcome(0, :builder, :failed, %{checks_green: false, failing_acceptance: 0}),
      outcome(1, "sol-medium", :failed, %{checks_green: true, failing_acceptance: 2})
    ]

    {state, effects} = Cycle.step(state, {:parallel_done, outcomes})
    assert {state.stage, state.attempt, state.rung} == {:develop, "sol-high", 2}

    assert [
             {:record, %{event: :parallel_selected, attempt: "sol-medium", result: :failed}},
             {:adopt, "sol-medium"},
             {:record, %{event: :escalation_started, previous_attempt: "sol-medium"}},
             {:escalate, %{summary: summary}},
             {:run, :develop, _args}
           ] = effects

    assert summary =~ "The builder attempt stopped"
    assert summary =~ "The sol-medium attempt stopped"
  end

  test "the planner's difficulty line decides; normal plans and plain recipes stay sequential" do
    hard = "**Difficulty:** Hard\n## Acceptance criteria\n1. Ready."
    {state, _effects} = Cycle.step(start(new()), {:stage_ok, :plan, %{plan_text: hard}})
    assert state.stage == :parallel

    for text <- ["Difficulty: easy\n## Steps", "## Steps without a rating"] do
      {state, effects} = Cycle.step(start(new()), {:stage_ok, :plan, %{plan_text: text}})
      assert state.stage == :develop
      assert [_stage_ok, {:run, :develop, _args}] = effects
    end

    plan_shell =
      Cycle.new(%{approval: :a, repairs: 2, recipe: Recipe.for_build("plan-shell", "m", "e")})

    {state, _effects} = Cycle.step(start(plan_shell), {:stage_ok, :plan, %{difficulty: :hard}})
    assert state.stage == :develop
  end

  test "an acceptance-only red gate is audited; full demotion counts the Candidate green" do
    state = developing(new())

    {state, effects} =
      Cycle.step(state, done_gate(:gate_red, %{acceptance_only: true, failure_count: 1}))

    assert {state.stage, state.audit_source} == {:audit, :done_gate}
    assert [{:run, :audit, %{source: :done_gate}}] = effects

    {state, effects} = Cycle.step(state, {:stage_ok, :audit, %{remaining: 0}})
    assert state.stage == :fix
    assert [{:record, %{event: :stage_ok}}, {:run, :fix, _args}] = effects
  end

  test "a valid acceptance test stays a real failure and is repaired" do
    state = developing(new())
    {state, _effects} = Cycle.step(state, done_gate(:gate_red, %{acceptance_only: true}))
    {state, effects} = Cycle.step(state, {:stage_ok, :audit, %{remaining: 1}})

    assert state.stage == :develop
    assert [{:record, %{event: :repair, reason: :done_gate_red}}, {:run, :develop, _}] = effects
  end

  test "acceptance-only check failures are audited and rechecked after demotion" do
    state = %{new() | stage: :check}
    failure = %Failure{class: :candidate, reason: :acceptance_red, detail: "A2"}

    {state, effects} = Cycle.step(state, {:stage_failed, :check, failure})
    assert [{:run, :audit, %{source: :check}}] = effects

    {state, effects} = Cycle.step(state, {:stage_ok, :audit, %{remaining: 0}})
    assert state.stage == :check
    assert [{:run, :check, _args}] = effects
  end

  test "a parallel member cycle starts at develop, finishes green, and never escalates" do
    member = Cycle.new(%{approval: :a, repairs: 2, recipe: @recipe, rung: 1, sub: true})
    assert member.attempt == "sol-medium"
    {member, [{:run, :develop, %{attempt: "sol-medium"}}]} = Cycle.step(member, :start)

    {green, effects} =
      member
      |> develop("tree-1")
      |> Cycle.step(done_gate(:done))
      |> elem(0)
      |> Cycle.step({:stage_ok, :fix, %{}})
      |> elem(0)
      |> Cycle.step({:stage_ok, :check, %{}})

    assert effects == [{:finish, :green, :green}]
    assert green.result == {:green, :green}

    {failed, effects} = Cycle.step(develop(member, "tree-1"), done_gate(:turn_cap))
    assert failed.result == {:failed, :turn_cap}
    assert effects == [{:finish, :failed, :turn_cap}]
  end

  test "an exhausted budget fails the Build" do
    {state, effects} = Cycle.step(developing(new()), :budget_exhausted)
    assert state.result == {:failed, :budget_exhausted}
    assert [{:record, %{event: :finished}}, {:finish, :failed, :budget_exhausted}] = effects
  end

  defp new, do: Cycle.new(%{approval: :approval, repairs: 2, recipe: @recipe})

  defp start(state) do
    {state, [{:run, :plan, _args}]} = Cycle.step(state, :start)
    state
  end

  defp developing(state) do
    {state, _effects} = Cycle.step(start(state), {:stage_ok, :plan, %{}})
    develop(state, "tree-0")
  end

  defp develop(state, tree) do
    {state, [{:record, %{event: :stage_ok}}]} =
      Cycle.step(state, {:stage_ok, :develop, %{tree: tree}})

    state
  end

  defp red_gate(state, count, findings) do
    Cycle.step(state, done_gate(:gate_red, %{failure_count: count, findings: findings}))
  end

  defp done_gate(outcome, extra \\ %{}),
    do: {:stage_ok, :done_gate, Map.merge(%{outcome: outcome}, extra)}

  defp outcome(index, attempt, status, metrics) do
    %{
      index: index,
      attempt: attempt,
      status: status,
      reason: if(status == :green, do: :green, else: :no_progress),
      findings: ["#{attempt} finding"],
      metrics: metrics
    }
  end
end
