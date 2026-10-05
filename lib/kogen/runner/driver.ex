defmodule Kogen.Runner.Driver do
  @moduledoc false

  # Interprets Cycle effects for one Candidate session. The main Build finishes through
  # Finish (land, park or fail); a parallel ladder member stops at green or failed and hands
  # its session back to the Ladder.

  alias Kogen.Build.Cycle
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.Finish
  alias Kogen.Engine.Build.Result
  alias Kogen.Engine.Build.Session
  alias Kogen.Engine.Build.StageRunner
  alias Kogen.Runner.Audit
  alias Kogen.Runner.Ladder
  alias Kogen.Runner.Landing
  alias Kogen.State

  @type member_result :: {:green | :failed, term(), Session.t()}

  @spec run(Session.t(), [Cycle.effect()]) :: {:ok, Result.t()} | {:error, term()}
  def run(%Session{} = session, effects) do
    case run_effects(session, effects, :main) do
      {:done, result} -> result
      {:continue, _session} -> {:error, :cycle_incomplete}
    end
  end

  @doc "Runs a parallel member's sub-cycle from its start to green or failed."
  @spec run_member(Session.t()) :: member_result()
  def run_member(%Session{} = session) do
    {cycle, effects} = Cycle.step(session.cycle, :start)

    case run_effects(%{session | cycle: cycle}, effects, :member) do
      {:done, result} -> result
      {:continue, session} -> {:failed, {:controller, :cycle_incomplete}, session}
    end
  end

  defp run_effects(session, [], mode), do: finish_if_terminal(session, mode)

  defp run_effects(session, [{:record, event} | rest], mode) do
    event =
      if event.event == :finished,
        do: Map.put(event, :verdict, session.landing_verdict),
        else: event

    case State.record(session.run, event) do
      :ok ->
        run_effects(add_record_line(session, event), rest, mode)

      {:error, reason} ->
        failure = %Failure{
          class: :controller,
          reason: :state_write_failed,
          detail: inspect(reason)
        }

        {:done, terminal_failure(session, failure, mode)}
    end
  end

  defp run_effects(session, [{:run, stage, args} | rest], mode) do
    case run_stage(stage, args, session) do
      {:ok, updated, events} ->
        updated = add_stage_line(updated, stage, events)
        run_events_with_tail(updated, events, rest, mode)

      {:error, updated, failure} ->
        updated =
          updated
          |> wall_spent(session, failure)
          |> add_stage_line(stage, [{:stage_failed, stage, failure}])

        apply_effect_event(updated, {:stage_failed, stage, failure}, rest, mode)

      {:parked, updated, reason} ->
        apply_effect_event(updated, {:park, reason}, rest, mode)

      {:base_moved, updated} ->
        apply_effect_event(updated, {:base_moved}, rest, mode)
    end
  end

  defp run_effects(session, [{:escalate, args} | rest], mode) do
    case Ladder.escalate(session, args) do
      {:ok, updated} -> run_effects(updated, rest, mode)
      {:budget_exhausted, updated} -> apply_effect_event(updated, :budget_exhausted, [], mode)
      {:error, updated, failure} -> apply_effect_event(updated, failed(failure), rest, mode)
    end
  end

  defp run_effects(session, [{:pause, data} | rest], mode) do
    case Ladder.pause(session, data) do
      {:ok, updated} -> run_effects(updated, rest, mode)
      {:budget_exhausted, updated} -> apply_effect_event(updated, :budget_exhausted, [], mode)
    end
  end

  defp run_effects(session, [{:parallel, data} | rest], mode) do
    {:ok, updated, outcomes} = Ladder.parallel(session, data, &run_member/1)
    apply_effect_event(updated, {:parallel_done, outcomes}, rest, mode)
  end

  defp run_effects(session, [{:edge, _data} | rest], mode) do
    case Ladder.edge(session, &run_member/1) do
      {:ok, updated, attempt} -> apply_effect_event(updated, {:edge_done, attempt}, rest, mode)
      {:error, updated, failure} -> {:done, terminal_failure(updated, failure, mode)}
    end
  end

  defp run_effects(session, [{:adopt, attempt} | rest], mode) do
    case Ladder.adopt(session, attempt) do
      {:ok, updated} -> run_effects(updated, rest, mode)
      {:error, updated, failure} -> {:done, terminal_failure(updated, failure, mode)}
    end
  end

  defp run_effects(session, [{:finish, status, reason} | _rest], mode),
    do: {:done, finish(session, status, reason, mode)}

  defp run_stage(:commit, _args, session), do: Landing.prepare(session)
  defp run_stage(:land, args, session), do: Landing.land(args, session)
  defp run_stage(:audit, args, session), do: Audit.run(args, session)
  defp run_stage(stage, args, session), do: StageRunner.run(stage, args, session)

  defp run_events(session, [], mode), do: finish_if_terminal(session, mode)

  defp run_events(session, [event | rest], mode) do
    case apply_event(session, event, mode) do
      {:continue, updated} -> run_events(updated, rest, mode)
      {:done, result} -> {:done, result}
    end
  end

  defp apply_event(session, event, mode) do
    {cycle, effects} = Cycle.step(session.cycle, event)
    run_effects(%{session | cycle: cycle}, effects, mode)
  end

  defp run_events_with_tail(session, events, tail, mode) do
    case run_events(session, events, mode) do
      {:continue, updated} -> run_effects(updated, tail, mode)
      {:done, result} -> {:done, result}
    end
  end

  defp apply_effect_event(session, event, tail, mode) do
    case apply_event(session, event, mode) do
      {:continue, updated} -> run_effects(updated, tail, mode)
      {:done, result} -> {:done, result}
    end
  end

  # The exchange retries timeouts, stalls and transport failures until the stage's wall runs
  # out; the cycle ends such an attempt like a wall cap, so it is not the Build's failure.
  defp wall_spent(updated, before, %Failure{class: :provider, reason: reason})
       when reason in [:timeout, :stall, :transport],
       do: %{updated | failure: before.failure, failure_text: before.failure_text}

  defp wall_spent(updated, _before, _failure), do: updated

  defp failed(%Failure{} = failure), do: {:stage_failed, :develop, failure}

  defp finish_if_terminal(session, mode) do
    case session.cycle.result do
      {status, reason} -> {:done, finish(session, status, reason, mode)}
      nil -> {:continue, session}
    end
  end

  defp finish(session, status, reason, :member), do: {status, reason, session}

  defp finish(session, status, reason, :main) do
    _recorded =
      Ladder.rung_finished(session, if(status == :landed, do: :green, else: status), reason)

    Finish.run(session, status, reason)
  end

  defp terminal_failure(session, %Failure{} = failure, :member),
    do: {:failed, {failure.class, failure.reason}, %{session | failure: failure}}

  defp terminal_failure(session, failure, :main), do: Finish.terminal_failure(session, failure)

  defp add_stage_line(session, stage, events) do
    session = %{session | lines: session.lines ++ [stage_line(stage, events)]}

    # A provider failure is retried or paused, so it must not replace the repair feedback.
    case events do
      [{:stage_failed, _stage, %Failure{class: :provider, reason: reason}}]
      when reason in [:timeout, :stall, :transport] ->
        session

      [{:stage_failed, _stage, %Failure{class: :provider} = failure}] ->
        %{session | failure: failure}

      [{:stage_failed, _stage, failure}] ->
        %{session | failure: failure, failure_text: failure.detail}

      _events ->
        session
    end
  end

  defp stage_line(:context, _events), do: "context: complete"
  defp stage_line(:plan, _events), do: "plan: complete"
  defp stage_line(:fix, _events), do: "fix: complete"
  defp stage_line(:check, _events), do: "checks + acceptance: pass"
  defp stage_line(:review, [{:review, verdict, _findings}]), do: "review: #{verdict}"
  defp stage_line(:develop, events), do: "develop: #{develop_outcome(events)}"

  defp stage_line(:commit, [{:stage_ok, :commit, data}]),
    do: "commit: #{Map.get(data, :candidate_commit, "complete")}"

  defp stage_line(:land, _events), do: "land: complete"
  defp stage_line(stage, _events), do: "#{stage}: complete"

  defp develop_outcome([_first, {:stage_ok, :done_gate, %{outcome: outcome}}]), do: outcome
  defp develop_outcome(_events), do: :complete

  defp add_record_line(session, %{event: :repair, reason: reason}),
    do: %{session | lines: session.lines ++ ["repair: #{reason}"]}

  defp add_record_line(session, _event), do: session
end
