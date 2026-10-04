defmodule Kogen.Build.CyclePropertyTest do
  @moduledoc """
  Generated properties for the pure Build cycle.

  A small simulator plays the engine: after each step it looks at the `:run`
  effect the cycle asked for and offers every plausible answer to it (success,
  each failure class, base moved, malformed data). Deterministically seeded
  choice lists make each generated path reproducible without global test state.
  Invariants are checked after every step.
  """
  use ExUnit.Case, async: true

  alias Kogen.Build.Cycle
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure

  @run_stages [:context, :plan, :develop, :fix, :check, :review, :commit, :land]
  @terminal [:landed, :failed, :parked]
  @classes [:candidate, :environment, :provider, :controller]
  @max_events 60
  @property_runs 300

  # Classes the engine can really produce per stage today (stage_runner.ex, commit.ex).
  # `:all` explores the full contract `Cycle.step/2` accepts (any Failure on any stage).
  @engine_classes %{
    context: [:environment, :provider, :controller],
    plan: [:environment, :provider, :controller],
    develop: [:candidate, :environment, :provider, :controller],
    done_gate: [],
    fix: [:candidate, :environment, :controller],
    check: [:candidate, :environment, :controller],
    review: [:candidate, :environment, :provider, :controller],
    commit: [:candidate, :environment, :controller],
    land: [:candidate, :controller]
  }

  describe "driven by a simulated engine" do
    test "full contract: no crash, invariants hold, every run terminates" do
      for seed <- 1..@property_runs do
        simulate(seed, rem(seed, 4), :all)
      end
    end

    test "engine-realistic failures: no crash, invariants hold, every run terminates" do
      for seed <- 1..@property_runs do
        simulate(seed + 10_000, rem(seed, 4), :engine)
      end
    end
  end

  test "any event in any reachable state is absorbed or fails closed, never raises" do
    for seed <- 1..@property_runs do
      repairs = rem(seed, 4)
      prefix = choices(seed + 20_000, 25)

      {state, _trace} =
        drive(
          Cycle.new(%{
            approval: %{slug: "p"},
            repairs: repairs,
            recipe: Recipe.for_build("staged", "scripted-model", "medium")
          }),
          prefix
        )

      event = garbage_event(seed + 30_000)
      {next, effects} = Cycle.step(state, event)
      check_step!(state, event, next, effects, [])
    end
  end

  # --- simulator -----------------------------------------------------------

  defp simulate(seed, repairs, mode) do
    state =
      Cycle.new(%{
        approval: %{slug: "p"},
        repairs: repairs,
        recipe: Recipe.for_build("staged", "scripted-model", "medium")
      })

    {state, pending} = start(state)
    loop(state, pending, choices(seed, @max_events), mode, [], 0)
  end

  defp choices(seed, count) do
    {values, _state} =
      Enum.map_reduce(1..count, seed, fn _step, state ->
        next = rem(state * 48_271, 2_147_483_647)
        {rem(next, 100_001), next}
      end)

    values
  end

  defp start(state) do
    {state, effects} = Cycle.step(state, :start)
    {state, pending_after(state, effects)}
  end

  defp loop(%Cycle.State{result: result} = state, _pending, _choices, _mode, trace, _n)
       when not is_nil(result) do
    # Terminal: must absorb every further event.
    assert Cycle.step(state, {:base_moved}) == {state, []}
    assert Cycle.step(state, {:stage_ok, :context, %{}}) == {state, []}
    check_landing_safety!(state, Enum.reverse(trace))
  end

  defp loop(state, _pending, [], _mode, trace, n) do
    flunk(
      "no terminal state after #{n} events; stage=#{state.stage} trace=#{inspect(Enum.reverse(trace))}"
    )
  end

  defp loop(state, pending, [choice | rest], mode, trace, n) do
    event = pick(pending, state, mode, choice)
    {next, effects} = Cycle.step(state, event)
    check_step!(state, event, next, effects, trace)
    trace = [{event, effects} | trace]
    loop(next, pending_after(next, effects), rest, mode, trace, n + 1)
  end

  defp pending_after(state, effects) do
    case Enum.find(effects, &match?({:run, _, _}, &1)) do
      {:run, stage, args} -> {:run, stage, args}
      nil when state.stage == :done_gate -> {:run, :done_gate}
      nil -> :none
    end
  end

  defp drive(state, choices) do
    {state, pending} = start(state)

    choices
    |> Enum.reduce_while({state, pending, []}, fn choice, {s, pending, trace} ->
      if s.result do
        {:halt, {s, pending, trace}}
      else
        event = pick(pending, s, :engine, choice)
        {next, effects} = Cycle.step(s, event)
        {:cont, {next, pending_after(next, effects), [event | trace]}}
      end
    end)
    |> then(fn {s, _pending, trace} -> {s, trace} end)
  end

  # Bias towards success (80%) so deep paths (commit, land, repairs after review) are reached.
  defp pick(pending, state, mode, choice) do
    stage = pending_stage(pending)

    list =
      if stage && rem(choice, 100) < 80, do: ok(stage), else: answers(pending, state, mode)

    Enum.at(list, rem(div(choice, 100), length(list)))
  end

  defp pending_stage({:run, stage}), do: stage
  defp pending_stage({:run, stage, _args}), do: stage
  defp pending_stage(:none), do: nil

  # Every answer the engine could plausibly send for the pending run.
  defp answers(:none, _state, _mode), do: [{:base_moved}]

  defp answers({:run, stage}, state, mode), do: answers({:run, stage, %{}}, state, mode)

  defp answers({:run, stage, _args}, _state, mode) do
    ok(stage) ++ failures(stage, mode) ++ [{:base_moved}]
  end

  defp ok(:develop) do
    for tree <- ["t1", "t2", nil], do: {:stage_ok, :develop, %{tree: tree}}
  end

  defp ok(:done_gate) do
    for outcome <- [:done, :done, :gate_red, :gave_up, :bogus],
        do: {:stage_ok, :done_gate, %{outcome: outcome}}
  end

  defp ok(:review) do
    [
      {:review, :accept, []},
      {:review, :revise, ["A1"]},
      {:stage_ok, :review, %{verdict: :accept, findings: []}},
      {:stage_ok, :review, %{verdict: :maybe}}
    ]
  end

  defp ok(:commit), do: [{:stage_ok, :commit, landing()}, {:stage_ok, :commit, %{}}]
  defp ok(:land), do: [{:landed, "c1"}, {:stage_ok, :land, %{sha: "c1"}}]
  defp ok(stage), do: [{:stage_ok, stage, %{}}]

  defp failures(stage, :all), do: for(c <- @classes, do: failed(stage, c))

  defp failures(stage, :engine),
    do: for(c <- Map.fetch!(@engine_classes, stage), do: failed(stage, c))

  defp failed(stage, class) do
    reason = if class == :candidate and stage == :check, do: :scope_edit, else: :red
    {:stage_failed, stage, %Failure{class: class, reason: reason, detail: "d"}}
  end

  defp landing do
    %{
      approval_commit: "a",
      run_id: "r",
      expected_parent: "p",
      final_tree: "t",
      candidate_commit: "c1"
    }
  end

  # --- invariants ----------------------------------------------------------

  defp check_step!(prev, event, next, effects, trace) do
    ctx = step_context(prev, event, next, effects, trace)

    if prev.result do
      assert {next, effects} == {prev, []}, ctx.("terminal state changed")
    else
      check_active_step!(prev, next, effects, ctx)
    end
  end

  defp step_context(prev, event, next, effects, trace) do
    fn msg ->
      "#{msg}\n  prev: #{inspect(prev)}\n  event: #{inspect(event)}\n  next: #{inspect(next)}\n" <>
        "  effects: #{inspect(effects)}\n  events so far: #{inspect(Enum.reverse(Enum.map(trace, &elem(&1, 0))))}"
    end
  end

  defp check_active_step!(prev, next, effects, ctx) do
    assert next.repairs_left in max(prev.repairs_left - 1, 0)..prev.repairs_left//1,
           ctx.("repairs_left moved by more than one or grew")

    assert next.provider_retries in prev.provider_retries..2//1,
           ctx.("provider retries out of range")

    Enum.each(effects, fn effect ->
      assert well_formed?(effect), ctx.("malformed effect #{inspect(effect)}")
    end)

    check_active_effects!(next, effects, ctx)
  end

  defp check_active_effects!(next, effects, ctx) do
    runs = for {:run, stage, args} <- effects, do: {stage, args}
    finishes = for {:finish, _, _} = finish <- effects, do: finish
    assert length(runs) <= 1, ctx.("more than one run effect")

    case next.result do
      {status, reason} ->
        check_terminal!(next, runs, effects, status, reason, ctx)

      nil ->
        check_nonterminal!(next, runs, finishes, ctx)
    end
  end

  defp check_terminal!(next, runs, effects, status, reason, ctx) do
    assert status in @terminal, ctx.("unknown terminal status")
    assert next.stage == status, ctx.("terminal stage differs from result")
    assert next.pending_land == false, ctx.("terminal with pending_land")
    assert runs == [], ctx.("run effect on a terminal step")
    assert List.last(effects) == {:finish, status, reason}, ctx.("finish is not last")
  end

  defp check_nonterminal!(next, runs, finishes, ctx) do
    assert finishes == [], ctx.("finish without result")

    case runs do
      [] ->
        assert next.stage == :done_gate, ctx.("non-terminal step asks for nothing: engine stalls")

      [{stage, args}] ->
        check_pending_run!(next, stage, args, ctx)
    end
  end

  defp check_pending_run!(next, stage, args, ctx) do
    assert stage in @run_stages, ctx.("unknown run stage")

    assert run_matches_stage?(stage, next.stage),
           ctx.("run #{stage} while stage is #{next.stage}")

    if stage == :land do
      assert is_binary(Map.get(args, :expected_parent)) and
               is_binary(Map.get(args, :candidate_commit)),
             ctx.("land run without landing identity (Commit.land does Map.fetch!)")
    end
  end

  defp well_formed?({:run, stage, args}) when is_atom(stage) and is_map(args), do: true
  defp well_formed?({:record, %{event: e}}) when is_atom(e), do: true
  defp well_formed?({:finish, s, _}) when s in @terminal, do: true
  defp well_formed?(_), do: false

  defp run_matches_stage?(stage, stage), do: true
  defp run_matches_stage?(_, _), do: false

  # Nothing unverified lands: a landing needs, since the last repair, a passed done gate,
  # fix, check, review accept and a recorded landing identity, in that order.
  defp check_landing_safety!(%Cycle.State{result: {:landed, _}}, trace) do
    since_repair =
      trace
      |> Enum.reverse()
      |> Enum.take_while(fn {_e, effects} ->
        not Enum.any?(effects, &match?({:record, %{event: :repair}}, &1))
      end)
      |> Enum.reverse()
      |> Enum.flat_map(fn {_e, effects} -> effects end)

    order = [:fix, :check, :review, :commit, :land]
    ran = for {:run, s, _} <- since_repair, s in order, do: s

    assert ordered_subsequence?(ran, order),
           "landed without the full verified path: #{inspect(ran)}"

    assert Enum.any?(since_repair, &match?({:record, %{event: :review_accept}}, &1))
    assert Enum.any?(since_repair, &match?({:record, %{event: :landing_prepared}}, &1))
  end

  defp check_landing_safety!(_state, _trace), do: :ok

  defp ordered_subsequence?(_values, []), do: true
  defp ordered_subsequence?([], _required), do: false

  defp ordered_subsequence?([value | values], [value | required]),
    do: ordered_subsequence?(values, required)

  defp ordered_subsequence?([_value | values], required),
    do: ordered_subsequence?(values, required)

  # --- garbage events -------------------------------------------------------

  defp small_term(seed) do
    Enum.at([seed, :unexpected, Integer.to_string(seed), nil, %{}], rem(seed, 5))
  end

  defp garbage_event(seed) do
    stages = @run_stages ++ [:done_gate, :landed, :bogus]
    stage = Enum.at(stages, rem(seed, length(stages)))
    classes = @classes ++ [:unknown]
    class = Enum.at(classes, rem(div(seed, 10), length(classes)))
    keys = [:tree, :outcome, :verdict, :sha, :findings]

    data =
      keys
      |> Enum.take(rem(div(seed, 7), length(keys) + 1))
      |> Map.new(&{&1, small_term(seed + byte_size(Atom.to_string(&1)))})

    case rem(seed, 10) do
      0 -> {:base_moved}
      1 -> :unknown
      2 -> small_term(seed)
      3 -> {:stage_ok, stage, data}
      4 -> {:stage_ok, stage, small_term(seed)}
      5 -> {:stage_failed, stage, %Failure{class: class, reason: :r, detail: "d"}}
      6 -> {:stage_failed, stage, :malformed_failure}
      7 -> {:review, Enum.at([:accept, :revise, :maybe], rem(seed, 3)), small_term(seed)}
      8 -> {:landed, small_term(seed)}
      9 -> {:unrecognized, stage, data}
    end
  end
end
