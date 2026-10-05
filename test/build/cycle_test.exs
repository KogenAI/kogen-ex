defmodule Kogen.Build.CycleTest do
  use Kogen.Testkit.Case

  alias Kogen.Build.Cycle
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure

  test "transition table covers every stage and failure transition" do
    rows = transition_rows()

    assert length(rows) >= 25

    Enum.each(rows, fn {name, state, event, expected_stage, repairs_left, effect_kind} ->
      {next, effects} = Cycle.step(state, event)

      assert next.stage == expected_stage, name
      assert next.repairs_left == repairs_left, name
      assert effect_kind(effects) == effect_kind, name
    end)
  end

  test "landing identity is recorded before the land effect" do
    state = state_at(:commit)
    {next, effects} = Cycle.step(state, {:stage_ok, :commit, landing_data()})

    assert next.pending_land

    assert [{:record, %{event: :landing_prepared, landing: identity}}, {:run, :land, identity}] =
             effects

    assert identity.run_id == "run-1"
    assert identity.candidate_commit == "candidate"
  end

  test "provider failures during commit and land retry the commit stage" do
    for {stage, pending_land} <- [{:commit, false}, {:land, true}] do
      state = state_at(stage, pending_land: pending_land)

      {retry, effects} =
        Cycle.step(state, {:stage_failed, stage, failure(:provider, :overload)})

      assert retry.stage == :commit
      refute retry.pending_land
      assert retry.provider_retries == 1
      assert [{:record, %{event: :provider_retry}}, {:run, :commit, args}] = effects
      assert args.provider_retry == 1

      {prepared, effects} = Cycle.step(retry, {:stage_ok, :commit, landing_data()})

      assert prepared.stage == :land
      assert prepared.pending_land
      assert [{:record, %{event: :landing_prepared}}, {:run, :land, landing}] = effects
      assert landing.expected_parent == "parent"
      assert landing.candidate_commit == "candidate"
    end
  end

  test "one progress repair is earned when a red done gate has fewer failing tests" do
    state = state_at(:done_gate, repairs_left: 0, last_failed_test_count: 4)

    {retry, effects} =
      Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red, failed_test_count: 2}})

    assert retry.stage == :develop
    assert retry.repairs_left == 0
    assert retry.last_failed_test_count == 2
    assert retry.progress_repair_used?

    assert [
             {:record,
              %{
                event: :repair,
                detail: %{
                  test_progress: %{
                    previous_failed_test_count: 4,
                    failed_test_count: 2,
                    progress_repair_granted: true
                  }
                }
              }},
             {:run, :develop, _args}
           ] = effects

    {retry, _effects} = Cycle.step(retry, {:stage_ok, :develop, %{tree: "tree-1"}})

    {stopped, effects} =
      Cycle.step(retry, {:stage_ok, :done_gate, %{outcome: :gate_red, failed_test_count: 1}})

    assert {:failed, :repair_cap} = stopped.result
    assert stopped.last_failed_test_count == 1

    assert [{:record, %{event: :finished, reason: :repair_cap}}, {:finish, :failed, :repair_cap}] =
             effects
  end

  test "an uncountable red gate breaks the test-progress comparison" do
    state = state_at(:done_gate, repairs_left: 1, last_failed_test_count: 4)

    {retry, _effects} =
      Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red, failed_test_count: nil}})

    assert retry.stage == :develop
    assert retry.repairs_left == 0
    assert is_nil(retry.last_failed_test_count)

    {retry, _effects} = Cycle.step(retry, {:stage_ok, :develop, %{tree: "tree-1"}})

    {stopped, _effects} =
      Cycle.step(retry, {:stage_ok, :done_gate, %{outcome: :gate_red, failed_test_count: 2}})

    assert {:failed, :repair_cap} = stopped.result
  end

  test "the cycle stays pure across a complete successful path" do
    state = Cycle.new(%{approval: %{slug: "sample"}, repairs: 2, recipe: staged_recipe()})
    {state, [{:run, :context, _args}]} = Cycle.step(state, :start)

    {state, _} = Cycle.step(state, {:stage_ok, :context, %{}})
    {state, _} = Cycle.step(state, {:stage_ok, :plan, %{}})
    {state, _} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})
    {state, _} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :done}})
    {state, _} = Cycle.step(state, {:stage_ok, :fix, %{}})
    {state, _} = Cycle.step(state, {:stage_ok, :check, %{status: :pass}})
    {state, [{:record, _}, {:run, :commit, _args}]} = Cycle.step(state, {:review, :accept, []})

    {state, [{:record, %{event: :landing_prepared}}, {:run, :land, _landing}]} =
      Cycle.step(state, {:stage_ok, :commit, landing_data()})

    {state, effects} = Cycle.step(state, {:landed, "candidate"})

    assert state.stage == :landed
    assert state.result == {:landed, "candidate"}
    assert [{:record, %{event: :finished}}, {:finish, :landed, "candidate"}] = effects
  end

  test "direct recipe runs its ordered path without plan or review effects" do
    recipe = Recipe.for_build("direct", "scripted-model", "medium")
    assert recipe.stages == [:develop, :done_gate, :fix, :check, :commit, :land]

    state = Cycle.new(%{approval: %{slug: "sample"}, repairs: 2, recipe: recipe})
    {state, [{:run, :develop, _args}]} = Cycle.step(state, :start)
    {state, _} = Cycle.step(state, {:stage_ok, :develop, %{tree: "tree-1"}})

    {state, [{:record, %{event: :stage_ok}}, {:run, :fix, _args}]} =
      Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :done}})

    {state, [{:record, _}, {:run, :check, _args}]} = Cycle.step(state, {:stage_ok, :fix, %{}})

    {state, [{:record, _}, {:run, :commit, _args}]} =
      Cycle.step(state, {:stage_ok, :check, %{status: :pass}})

    {state, [{:record, %{event: :landing_prepared}}, {:run, :land, _args}]} =
      Cycle.step(state, {:stage_ok, :commit, landing_data()})

    {state, [{:record, %{event: :finished}}, {:finish, :landed, "candidate"}]} =
      Cycle.step(state, {:landed, "candidate"})

    assert state.stage == :landed
  end

  test "direct-shell recipe keeps the direct path and selects shell-only builder tools" do
    recipe = Recipe.for_build("direct-shell", "scripted-model", "medium")

    assert Recipe.name(recipe) == "direct-shell"
    assert recipe.stages == [:develop, :done_gate, :fix, :check, :commit, :land]
    assert recipe.builder_tools == :shell
    assert recipe.roles == %{builder: {"scripted-model", "medium"}}

    state = Cycle.new(%{approval: %{slug: "sample"}, repairs: 2, recipe: recipe})
    {state, [{:run, :develop, _args}]} = Cycle.step(state, :start)
    assert state.stage == :develop
  end

  test "plan-shell and escalate-shell follow their declared Cycle stage order" do
    for name <- ["plan-shell", "escalate-shell"] do
      recipe = Recipe.for_build(name, "scripted-model", "medium")

      assert recipe.builder_tools == :shell
      assert successful_cycle_stages(recipe) == recipe.stages
    end
  end

  test "direct-escalate only escalates terminal builder failures once" do
    recipe = Recipe.for_build("direct-escalate", "gpt-6-luna", "max")

    trigger_events = [
      {:gate_red, state_at(:done_gate, recipe: recipe, repairs_left: 0),
       {:stage_ok, :done_gate, %{outcome: :gate_red, findings: ["A1 is still red"]}}},
      {:unchanged, state_at(:develop, recipe: recipe, repair_tree: "tree-1"),
       {:stage_ok, :develop, %{tree: "tree-1"}}},
      {:repair_cap, state_at(:check, recipe: recipe, repairs_left: 0),
       {:stage_failed, :check, failure(:candidate, :red)}}
    ]

    for {trigger, state, event} <- trigger_events do
      {escalation, effects} = Cycle.step(state, event)

      assert escalation.attempt == :escalation
      assert escalation.escalation_used?
      assert escalation.stage == :develop
      assert escalation.repairs_left == escalation.repair_cap

      assert [
               {:record, %{event: :escalation_started, trigger: ^trigger}},
               {:escalate, %{trigger: ^trigger} = data},
               {:run, :develop, %{attempt: :escalation} = args}
             ] = effects

      assert args.escalation_summary == data.summary

      if trigger == :gate_red, do: assert(data.summary =~ "A1 is still red")
    end
  end

  test "direct-escalate waits for the repair cap and does not escalate twice" do
    recipe = Recipe.for_build("direct-escalate", "gpt-6-luna", "max")
    state = state_at(:done_gate, recipe: recipe, repairs_left: 1)

    {repair, effects} =
      Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :gate_red, findings: ["A1 red"]}})

    assert repair.stage == :develop
    assert repair.attempt == :builder
    assert repair.repairs_left == 0
    refute Enum.any?(effects, &match?({:escalate, _args}, &1))

    escalated =
      state_at(:done_gate,
        recipe: recipe,
        attempt: :escalation,
        escalation_used?: true,
        repairs_left: 0
      )

    {failed, effects} =
      Cycle.step(escalated, {:stage_ok, :done_gate, %{outcome: :gate_red}})

    assert {:failed, :repair_cap} = failed.result
    refute Enum.any?(effects, &match?({:escalate, _args}, &1))
  end

  defp state_at(stage, overrides \\ []) do
    state = Cycle.new(%{approval: %{slug: "sample"}, repairs: 2, recipe: staged_recipe()})

    struct!(state, Keyword.put(overrides, :stage, stage))
  end

  defp successful_cycle_stages(recipe) do
    state = Cycle.new(%{approval: %{slug: "sample"}, repairs: 2, recipe: recipe})
    {state, effects} = Cycle.step(state, :start)
    drive_successful_cycle(state, run_stages(effects))
  end

  defp drive_successful_cycle(%{stage: :done_gate} = state, stages) do
    {next, effects} = Cycle.step(state, {:stage_ok, :done_gate, %{outcome: :done}})
    drive_successful_cycle(next, stages ++ [:done_gate] ++ run_stages(effects))
  end

  defp drive_successful_cycle(%{stage: :land} = state, stages) do
    {landed, effects} = Cycle.step(state, {:landed, "candidate"})
    assert landed.result == {:landed, "candidate"}
    assert [{:record, %{event: :finished}}, {:finish, :landed, "candidate"}] = effects
    stages
  end

  defp drive_successful_cycle(state, stages) do
    {next, effects} = Cycle.step(state, cycle_success_event(state.stage))
    drive_successful_cycle(next, stages ++ run_stages(effects))
  end

  defp cycle_success_event(:plan), do: {:stage_ok, :plan, %{}}
  defp cycle_success_event(:develop), do: {:stage_ok, :develop, %{tree: "tree-1"}}
  defp cycle_success_event(:fix), do: {:stage_ok, :fix, %{}}
  defp cycle_success_event(:check), do: {:stage_ok, :check, %{status: :pass}}
  defp cycle_success_event(:commit), do: {:stage_ok, :commit, landing_data()}

  defp run_stages(effects) do
    Enum.flat_map(effects, fn
      {:run, stage, _args} -> [stage]
      _effect -> []
    end)
  end

  defp staged_recipe, do: Recipe.for_build("staged", "scripted-model", "medium")

  defp failure(class, reason), do: %Failure{class: class, reason: reason, detail: "tail"}

  defp landing_data do
    %{
      approval_commit: "approval",
      run_id: "run-1",
      expected_parent: "parent",
      final_tree: "tree-1",
      candidate_commit: "candidate"
    }
  end

  defp transition_rows, do: pipeline_rows() ++ repair_rows() ++ terminal_rows()

  defp pipeline_rows do
    [
      {"context succeeds", state_at(:context), {:stage_ok, :context, %{}}, :plan, 2, :plan_run},
      {"plan succeeds", state_at(:plan), {:stage_ok, :plan, %{}}, :develop, 2, :develop_run},
      {"developer succeeds", state_at(:develop), {:stage_ok, :develop, %{tree: "tree-1"}},
       :done_gate, 2, :record},
      {"done gate passes", state_at(:done_gate), {:stage_ok, :done_gate, %{outcome: :done}}, :fix,
       2, :fix_run},
      {"fix succeeds", state_at(:fix), {:stage_ok, :fix, %{}}, :check, 2, :check_run},
      {"checks pass", state_at(:check), {:stage_ok, :check, %{status: :pass}}, :review, 2,
       :review_run},
      {"review accepts", state_at(:review), {:review, :accept, []}, :commit, 2, :commit_run},
      {"commit records identity", state_at(:commit), {:stage_ok, :commit, landing_data()}, :land,
       2, :land_run},
      {"landing succeeds", state_at(:land, pending_land: true), {:landed, "candidate"}, :landed,
       2, :finish_landed}
    ]
  end

  defp repair_rows do
    [
      {"done gate red repairs", state_at(:done_gate),
       {:stage_ok, :done_gate, %{outcome: :gate_red}}, :develop, 1, :develop_run},
      {"review revises", state_at(:review), {:review, :revise, ["A1"]}, :develop, 1,
       :develop_run},
      {"review revise reaches cap", state_at(:review, repairs_left: 0), {:review, :revise, []},
       :failed, 0, :finish_failed},
      {"candidate check red repairs", state_at(:check, last_tree: "tree-1"),
       {:stage_failed, :check, failure(:candidate, :red)}, :develop, 1, :develop_run},
      {"candidate review failure repairs", state_at(:review, last_tree: "tree-1"),
       {:stage_failed, :review, failure(:candidate, :review_red)}, :develop, 1, :develop_run},
      {"landing conflict repairs", state_at(:land, pending_land: true, last_tree: "tree-1"),
       {:stage_failed, :land, failure(:candidate, :conflict)}, :develop, 1, :develop_run},
      {"candidate red at cap fails", state_at(:check, repairs_left: 0),
       {:stage_failed, :check, failure(:candidate, :red)}, :failed, 0, :finish_failed},
      {"unchanged repaired tree fails",
       state_at(:develop, repair_tree: "tree-1", repairs_left: 1),
       {:stage_ok, :develop, %{tree: "tree-1"}}, :failed, 1, :finish_failed},
      {"changed repaired tree advances",
       state_at(:develop, repair_tree: "tree-1", repairs_left: 1),
       {:stage_ok, :develop, %{tree: "tree-2"}}, :done_gate, 1, :record}
    ]
  end

  defp terminal_rows do
    [
      {"missing commit identity fails", state_at(:commit), {:stage_ok, :commit, %{}}, :failed, 2,
       :finish_failed},
      {"land stage cannot skip identity", state_at(:land),
       {:stage_ok, :land, %{sha: "candidate"}}, :failed, 2, :finish_failed},
      {"land stage_ok event is rejected after receipt", state_at(:land, pending_land: true),
       {:stage_ok, :land, %{sha: "candidate"}}, :failed, 2, :finish_failed},
      {"base moved parks", state_at(:land, pending_land: true), {:base_moved}, :parked, 2,
       :finish_parked},
      {"environment failure stops", state_at(:check),
       {:stage_failed, :check, failure(:environment, :missing_tool)}, :failed, 2, :finish_failed},
      {"provider retry one", state_at(:check),
       {:stage_failed, :check, failure(:provider, :overload)}, :check, 2, :check_run},
      {"a transport failure at the wall's end ends the attempt", state_at(:check),
       {:stage_failed, :check, failure(:provider, :transport)}, :failed, 2, :finish_failed},
      {"provider malformed retries", state_at(:check),
       {:stage_failed, :check, failure(:provider, :malformed)}, :check, 2, :check_run},
      {"a timeout at the wall's end does not repeat the whole Build stage", state_at(:check),
       {:stage_failed, :check, failure(:provider, :timeout)}, :failed, 2, :finish_failed},
      {"usage limit is never retried", state_at(:check),
       {:stage_failed, :check, failure(:provider, :usage_limit)}, :failed, 2, :finish_failed},
      {"login failure is never retried", state_at(:check),
       {:stage_failed, :check, failure(:provider, :login)}, :failed, 2, :finish_failed},
      {"provider cap stops", state_at(:check, provider_retries: 2),
       {:stage_failed, :check, failure(:provider, :overload)}, :failed, 2, :finish_failed},
      {"controller failure stops", state_at(:develop),
       {:stage_failed, :develop, failure(:controller, :bug)}, :failed, 2, :finish_failed},
      {"unknown failure class fails closed", state_at(:check),
       {:stage_failed, :check, failure(:unknown, :bug)}, :failed, 2, :finish_failed},
      {"review stage_ok event is rejected", state_at(:review),
       {:stage_ok, :review, %{verdict: :accept}}, :failed, 2, :finish_failed},
      {"wrong stage event fails", state_at(:check), {:stage_ok, :develop, %{}}, :failed, 2,
       :finish_failed},
      {"unknown event fails", state_at(:context), :unknown, :failed, 2, :finish_failed},
      {"terminal state ignores events", state_at(:landed, result: {:landed, "candidate"}),
       {:base_moved}, :landed, 2, :empty}
    ]
  end

  defp effect_kind([]), do: :empty
  defp effect_kind([{:finish, :failed, _reason} | _rest]), do: :finish_failed
  defp effect_kind([{:finish, :landed, _reason} | _rest]), do: :finish_landed
  defp effect_kind([{:finish, :parked, _reason} | _rest]), do: :finish_parked
  defp effect_kind([{:record, %{event: :landing_prepared}}, {:run, :land, _args}]), do: :land_run
  defp effect_kind([{:record, _record} | rest]) when rest != [], do: effect_kind(rest)
  defp effect_kind([{:run, :plan, _args} | _rest]), do: :plan_run
  defp effect_kind([{:run, :develop, _args} | _rest]), do: :develop_run
  defp effect_kind([{:run, :fix, _args} | _rest]), do: :fix_run
  defp effect_kind([{:run, :check, _args} | _rest]), do: :check_run
  defp effect_kind([{:run, :review, _args} | _rest]), do: :review_run
  defp effect_kind([{:run, :commit, _args} | _rest]), do: :commit_run
  defp effect_kind([{:record, _record} | _rest]), do: :record
end
