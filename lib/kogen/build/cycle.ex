defmodule Kogen.Build.Cycle do
  @moduledoc "Pure transition function for one Build attempt."

  alias Kogen.Build.Cycle.Escalation
  alias Kogen.Build.Cycle.EventData
  alias Kogen.Build.Cycle.Parallel
  alias Kogen.Build.Cycle.ProviderFailure
  alias Kogen.Build.Cycle.Repair
  alias Kogen.Build.Cycle.State
  alias Kogen.Build.Cycle.Stop
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure

  @type terminal :: :landed | :failed | :parked | :green
  @type run_stage ::
          :context | :plan | :develop | :fix | :check | :review | :audit | :commit | :land
  @type effect ::
          {:run, run_stage(), map()}
          | {:escalate, map()}
          | {:parallel, map()}
          | {:adopt, State.attempt()}
          | {:record, map()}
          | {:finish, terminal(), term()}

  @stage_success_events [:context, :plan, :develop, :done_gate, :fix, :check, :audit]

  @doc """
  Options: `approval`, `repairs` (a ladder recipe uses its own cap), `recipe`, and for one
  parallel ladder member `rung` plus `sub: true`. A sub-cycle starts at develop, never
  escalates, and finishes `:green` instead of committing.
  """
  @spec new(%{
          required(:approval) => term(),
          required(:repairs) => non_neg_integer(),
          required(:recipe) => Recipe.t(),
          optional(:rung) => non_neg_integer(),
          optional(:sub) => boolean()
        }) :: State.t()
  def new(%{approval: approval, repairs: repairs, recipe: recipe} = options)
      when is_integer(repairs) and repairs >= 0 and is_map(recipe) do
    if Recipe.stages(recipe) == [] do
      raise ArgumentError, "cycle recipe requires at least one stage"
    end

    repairs = Repair.cap(recipe, repairs)
    rung = Map.get(options, :rung, 0)

    %State{
      approval: approval,
      recipe: recipe,
      stage: :ready,
      rung: rung,
      sub?: Map.get(options, :sub, false),
      repairs_left: repairs,
      repair_cap: repairs,
      last_failed_test_count: nil,
      progress_repair_used?: false,
      provider_retries: 0,
      last_tree: nil,
      repair_tree: nil,
      pending_land: false,
      attempt: Recipe.rung_attempt(recipe, rung),
      escalation_used?: false,
      last_gate_findings: [],
      last_gate_summary: nil,
      result: nil
    }
  end

  def new(_options),
    do: raise(ArgumentError, "cycle requires an approval, repair count, and recipe")

  @spec step(State.t(), term()) :: {State.t(), [effect()]}
  def step(%State{result: result} = state, _event) when not is_nil(result), do: {state, []}

  def step(%State{stage: :ready, sub?: true} = state, :start) do
    next = %{state | stage: :develop}
    {next, [run(:develop, stage_args(next))]}
  end

  def step(%State{stage: :ready} = state, :start) do
    case List.first(Recipe.stages(state.recipe)) do
      stage when stage in [:context, :plan, :develop] ->
        next = %{state | stage: stage}
        {next, [run(stage, stage_args(next))]}

      _other ->
        fail_controller(state, :invalid_recipe_start)
    end
  end

  def step(state, {:stage_ok, stage, data}) when is_map(data) do
    cond do
      stage == state.stage and stage in @stage_success_events ->
        stage_succeeded(state, stage, data)

      stage == :commit and state.stage == :commit ->
        commit_succeeded(state, data)

      true ->
        fail_controller(state, :unexpected_stage_event)
    end
  end

  def step(%State{stage: :review} = state, {:review, verdict, findings})
      when verdict in [:accept, :revise] and is_list(findings) do
    review_result(state, verdict, findings)
  end

  def step(%State{stage: :land, pending_land: true} = state, {:landed, sha})
      when is_binary(sha) do
    finish(state, :landed, sha)
  end

  def step(state, {:base_moved}) do
    finish(state, :parked, :base_moved)
  end

  def step(state, :budget_exhausted), do: finish(state, :failed, :budget_exhausted)

  def step(%State{stage: :parallel} = state, {:parallel_done, [_ | _] = outcomes}) do
    {next, winner, effects} = Parallel.done(state, outcomes)

    case winner.status do
      :green ->
        next = %{next | stage: :commit, pending_land: false}
        {next, effects ++ [run(:commit, stage_args(next, %{findings: []}))]}

      _red ->
        {after_red, more} = fail_candidate(next, winner.reason, :parallel_red)
        {after_red, effects ++ more}
    end
  end

  def step(%State{stage: :check} = state, {:stage_failed, :check, %Failure{} = failure})
      when failure.class == :candidate and failure.reason == :acceptance_red do
    if Recipe.auditor(state.recipe),
      do: audit(state, :check, nil),
      else: repair(state, :acceptance_red, %{failed_stage: :check})
  end

  def step(state, {:stage_failed, stage, %Failure{} = failure}) do
    if stage == state.stage and stage != :done_gate do
      handle_failure(state, stage, failure)
    else
      fail_controller(state, :unexpected_stage_event)
    end
  end

  def step(state, _event), do: fail_controller(state, :unexpected_event)

  defp stage_succeeded(state, :plan, data) do
    case Parallel.start(state, data) do
      {:ok, next, effects} -> {next, [stage_success_record(:plan) | effects]}
      :sequential -> advance_and_run(state, :plan)
    end
  end

  defp stage_succeeded(state, stage, _data) when stage in [:context, :fix, :check],
    do: advance_and_run(state, stage)

  defp stage_succeeded(state, :audit, data) do
    source = state.audit_source
    gate = state.pending_gate
    state = %{state | pending_gate: nil, audit_source: nil}

    cond do
      Map.get(data, :remaining) != 0 and source == :done_gate -> red_gate(state, gate)
      Map.get(data, :remaining) != 0 -> repair(state, :acceptance_red, %{failed_stage: :check})
      source == :done_gate -> advance_and_run(state, :done_gate)
      true -> {%{state | stage: :check}, [run(:check, stage_args(state))]}
    end
  end

  defp stage_succeeded(state, :develop, data) do
    tree = EventData.tree(data)

    if EventData.same_repaired_tree?(state.repair_tree, tree) do
      fail_candidate(state, :unchanged, :unchanged)
    else
      case next_recipe_stage(state, :develop) do
        :done_gate ->
          next = %{state | stage: :done_gate, last_tree: tree, repair_tree: nil}
          {next, [record(:stage_ok)]}

        _other ->
          fail_controller(state, :invalid_recipe_develop)
      end
    end
  end

  defp stage_succeeded(state, :done_gate, data) do
    state =
      case Map.get(data, :gate_summary) do
        summary when is_map(summary) -> %{state | last_gate_summary: summary}
        _summary -> state
      end

    case Map.get(data, :outcome, :done) do
      :done ->
        advance_and_run(state, :done_gate)

      :gate_red ->
        state = %{state | last_gate_findings: Escalation.findings(data)}

        if Recipe.auditor(state.recipe) && Map.get(data, :acceptance_only) == true,
          do: audit(state, :done_gate, data),
          else: red_gate(state, data)

      reason when reason in [:turn_cap, :wall_cap] ->
        fail_candidate(state, reason, reason)

      _other ->
        fail_controller(state, :invalid_done_gate)
    end
  end

  defp audit(state, source, gate) do
    next = %{state | stage: :audit, audit_source: source, pending_gate: gate}
    {next, [run(:audit, stage_args(next, %{source: source}))]}
  end

  defp red_gate(state, data) do
    {next, detail} = Repair.red_gate(state, data)
    repair(next, :done_gate_red, detail)
  end

  defp review_result(state, :accept, findings) do
    case next_recipe_stage(state, :review) do
      :commit ->
        next = %{state | stage: :commit, pending_land: false}

        {next,
         [
           record(:review_accept, %{findings: findings}),
           run(:commit, stage_args(next, %{findings: findings}))
         ]}

      _other ->
        fail_controller(state, :invalid_recipe_review)
    end
  end

  defp review_result(state, :revise, findings) do
    repair(state, :review_revise, %{findings: findings})
  end

  defp commit_succeeded(state, data) do
    case next_recipe_stage(state, :commit) do
      :land ->
        case EventData.landing_identity(data) do
          {:ok, identity} ->
            next = %{state | stage: :land, pending_land: true}

            {next,
             [
               {:record, %{event: :landing_prepared, landing: identity}},
               run(:land, identity)
             ]}

          :error ->
            fail_controller(state, :missing_landing_identity)
        end

      _other ->
        fail_controller(state, :invalid_recipe_commit)
    end
  end

  defp advance_and_run(state, completed_stage) do
    case next_recipe_stage(state, completed_stage) do
      :commit when state.sub? ->
        finish(state, :green, :green)

      next_stage when next_stage in [:plan, :develop, :fix, :check, :review, :commit] ->
        next = %{state | stage: next_stage}
        args = if next_stage == :commit, do: %{findings: []}, else: %{}

        {next, [stage_success_record(completed_stage), run(next_stage, stage_args(next, args))]}

      _other ->
        fail_controller(state, :invalid_recipe_sequence)
    end
  end

  defp next_recipe_stage(state, stage) do
    state.recipe
    |> Recipe.stages()
    |> Enum.drop_while(&(&1 != stage))
    |> case do
      [_current, next | _rest] -> next
      _last_or_missing -> nil
    end
  end

  defp handle_failure(state, stage, %Failure{class: :candidate, reason: reason}) do
    repair(state, reason, %{failed_stage: stage})
  end

  defp handle_failure(state, _stage, %Failure{class: :environment, reason: reason}) do
    finish(state, :failed, {:environment, reason})
  end

  defp handle_failure(state, stage, %Failure{class: :provider, reason: reason}) do
    case ProviderFailure.retry(state, stage, reason) do
      {:retry, next, effects} -> {next, effects}
      {:stop, result} -> fail_candidate(state, result, :provider_failed)
    end
  end

  defp handle_failure(state, _stage, %Failure{class: :controller, reason: reason}) do
    finish(state, :failed, {:controller, reason})
  end

  defp handle_failure(state, _stage, %Failure{}),
    do: finish(state, :failed, {:controller, :unknown_failure_class})

  defp repair(state, reason, detail) do
    case Repair.decide(state, reason, detail) do
      {:stop, stop_reason, trigger} ->
        fail_candidate(state, stop_reason, trigger)

      {:repair, next, detail} ->
        next = %{next | stage: :develop, repair_tree: state.last_tree, pending_land: false}

        {next,
         [
           record(:repair, %{reason: reason, repairs_left: next.repairs_left, detail: detail}),
           run(:develop, stage_args(next, %{repair: detail, reason: reason}))
         ]}
    end
  end

  defp fail_candidate(state, reason, trigger) do
    case Escalation.prepare(state, trigger) do
      {:ok, next, data} ->
        {next,
         [
           record(:escalation_started, data),
           {:escalate, data},
           run(:develop, stage_args(next, %{escalation_summary: data.summary, reason: trigger}))
         ]}

      :disabled ->
        finish(state, :failed, reason)
    end
  end

  defp fail_controller(state, reason) do
    finish(state, :failed, {:controller, reason})
  end

  defp finish(%State{sub?: true} = state, status, reason) do
    {%{state | stage: status, result: {status, reason}, pending_land: false},
     [{:finish, status, reason}]}
  end

  defp finish(state, status, reason) do
    next = %{state | stage: status, result: {status, reason}, pending_land: false}

    {next,
     [
       record(:finished, %{
         status: status,
         reason: reason,
         attempt: state.attempt,
         gate_summary: state.last_gate_summary,
         stop: Stop.summary(state, reason)
       }),
       {:finish, status, reason}
     ]}
  end

  defp stage_args(state, extra \\ %{}) do
    Map.merge(
      %{
        approval: state.approval,
        repairs_left: state.repairs_left,
        provider_retries: state.provider_retries,
        attempt: state.attempt
      },
      extra
    )
  end

  defp run(stage, args), do: {:run, stage, args}
  defp record(event), do: {:record, %{event: event}}
  defp record(event, data), do: {:record, Map.merge(%{event: event}, data)}

  defp stage_success_record(stage) when stage in [:context, :plan],
    do: record(:stage_ok, %{stage: stage})

  defp stage_success_record(_stage), do: record(:stage_ok)
end
