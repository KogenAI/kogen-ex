defmodule Kogen.Queue.Report do
  @moduledoc "The latest Build of an Intent as one JSON document: outcome, stages, checks and timings."

  alias Kogen.Queue.StateView
  alias Kogen.State
  alias Kogen.State.Event
  alias Kogen.State.Run
  alias Kogen.Workspace

  @spec read(String.t(), Path.t(), Path.t(), String.t(), map()) ::
          {:ok, binary()} | {:error, term()}
  def read(slug, state_root, origin, base, git_env) do
    with {:ok, runs} <- StateView.runs(state_root, slug),
         {:ok, %Run{} = run} <- StateView.latest(runs),
         {:ok, events} <- StateView.events(run),
         {:ok, interrupted?} <- StateView.interrupted?(run, events),
         status =
           (if interrupted? do
              :interrupted
            else
              State.status(origin, state_root, slug, base, git_env)
            end),
         {:ok, landed_sha} <- landed_sha(status, origin, base, slug, git_env) do
      encode(run, events, status, landed_sha)
    else
      {:ok, nil} -> {:error, :missing_run}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :report_unavailable}
  end

  defp landed_sha(:landed, origin, base, slug, git_env),
    do: Workspace.intent_commit(origin, base, slug, git_env)

  defp landed_sha(_status, _origin, _base, _slug, _git_env), do: {:ok, nil}

  defp encode(%Run{} = run, events, status, landed_sha) do
    report = json_object(identity(run, events, status, landed_sha) ++ outcome(run, events))
    {:ok, report |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ArgumentError -> {:error, :report_encoding_failed}
  end

  defp identity(run, events, status, landed_sha) do
    [
      {"slug", run.slug},
      {"status", Atom.to_string(status)},
      {"build_id", run.id},
      {"journal", run.dir},
      {"recipe", nullable(event_value(events, :recipe))},
      {"roles", event_value(events, :roles) || %{}},
      {"escalation", nullable(event_value(events, :escalation))},
      {"escalations", escalations(events)},
      {"attempts", attempts(events)},
      {"approval", nullable(run.approval_commit)},
      {"approved_by", nullable(event_value(events, :approved_by))},
      {"base", nullable(event_value(events, :base_sha) || landing_value(run, :expected_parent))},
      {"candidate", nullable(landing_value(run, :candidate_commit))},
      {"landed_sha", nullable(landed_sha)},
      {"credential",
       json_object([
         {"source", nullable(event_value(events, :credential_source))},
         {"label", nullable(event_value(events, :credential_label))}
       ])}
    ]
  end

  defp outcome(run, events) do
    [
      {"acceptance_results", event_payload(events, "acceptance_result", :ledger, [])},
      {"check_receipts", event_payload(events, "check_result", :receipts, [])},
      {"excused_flakes", excused_flakes(events)},
      {"candidate_diffs", candidate_diffs(run, events)},
      {"red_checks", latest_candidate_value(events, :red_checks, [])},
      {"acceptance_items", latest_candidate_value(events, :acceptance_items, [])},
      {"model_stages", model_stages(events)},
      {"phase_timings", phase_timings(events)},
      {"findings", findings(events)},
      {"failures", failures(events)},
      {"last_gate", last_gate(events)},
      {"stop", stop(events)},
      {"rungs", rungs(events)},
      {"parallel", parallel(events)},
      {"acceptance_demoted", demotions(events)},
      {"best_candidate", best_candidate(events)}
    ]
  end

  # Ladder Builds: each rung's time and cost, the parallel pick, demoted acceptance items,
  # and the best Candidate pushed for a human when no rung was green.
  defp rungs(events) do
    for %Event{event: "rung_finished"} = event <- events do
      json_object([
        {"attempt", event.attempt},
        {"rung", event.rung},
        {"experimental", event.experimental == true},
        {"model", event.model},
        {"effort", event.effort},
        {"result", event.result},
        {"reason", nullable(reason_text(event.reason))},
        {"wall_ms", event.wall_ms},
        {"tokens", event.tokens || %{}}
      ])
    end
  end

  defp parallel(events) do
    case Enum.find(events, &(&1.event == "parallel_selected")) do
      %Event{} = event ->
        json_object([
          {"selected", event.attempt},
          {"result", event.result},
          {"outcomes", event.outcomes || []}
        ])

      nil ->
        :null
    end
  end

  defp demotions(events) do
    for %Event{event: "acceptance_demoted"} = event <- events do
      json_object([
        {"item", event.item},
        {"verdict", event.verdict},
        {"reason", nullable(event.reason)},
        {"attempt", nullable(event.attempt)}
      ])
    end
  end

  defp best_candidate(events) do
    case Enum.find(Enum.reverse(events), &(&1.event == "best_candidate")) do
      %Event{} = event ->
        json_object([
          {"attempt", event.attempt},
          {"branch", event.branch},
          {"commit", event.commit},
          {"reason", nullable(reason_text(event.reason))},
          {"metrics", event.metrics || %{}},
          {"failing", event.failing || %{}},
          {"findings", event.findings || []}
        ])

      nil ->
        :null
    end
  end

  defp model_stages(events) do
    for %Event{event: "model_stage"} = event <- events do
      json_object([
        {"stage", event.stage},
        {"attempt", nullable(event.attempt)},
        {"model", event.model},
        {"effort", event.effort},
        {"tokens", event.tokens},
        {"wall_ms", event.wall_ms}
      ])
    end
  end

  defp escalations(events) do
    for %Event{event: "escalation_started"} = event <- events do
      json_object([
        {"attempt", event.attempt},
        {"trigger", event.trigger},
        {"summary", event.summary},
        {"findings", event.findings || []},
        {"model", event.model},
        {"effort", event.effort}
      ])
    end
  end

  defp attempts(events) do
    model_rows = Enum.filter(events, &(&1.event == "model_stage"))

    model_rows
    |> attempt_names(events)
    |> Enum.map(&attempt_summary(events, model_rows, &1))
  end

  defp attempt_names(model_rows, events) do
    model_attempts = Enum.map(model_rows, &(&1.attempt || "builder"))

    escalation_attempts =
      for %Event{event: "escalation_started", attempt: attempt} <- events, do: attempt

    finished_attempts = for %Event{event: "finished", attempt: attempt} <- events, do: attempt

    (model_attempts ++ escalation_attempts ++ finished_attempts)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp attempt_summary(events, model_rows, attempt) do
    rows = Enum.filter(model_rows, &((&1.attempt || "builder") == attempt))

    escalation =
      Enum.find(events, fn event ->
        event.event == "escalation_started" and
          (attempt == "builder" or event.attempt == attempt)
      end)

    final = Enum.find(events, &(&1.event == "finished" and &1.attempt == attempt))
    developer = Enum.find(rows, &(&1.stage == "develop"))
    {status, reason} = attempt_outcome(attempt, escalation, final)

    json_object([
      {"attempt", attempt},
      {"model", nullable((developer && developer.model) || (escalation && escalation.model))},
      {"effort", nullable((developer && developer.effort) || (escalation && escalation.effort))},
      {"status", nullable(status)},
      {"reason", nullable(reason)},
      {"tokens", sum_tokens(rows)},
      {"wall_ms", Enum.reduce(rows, 0, &(&1.wall_ms + &2))}
    ])
  end

  defp attempt_outcome("builder", %Event{trigger: trigger}, _final), do: {"failed", trigger}
  defp attempt_outcome(_attempt, _escalation, %Event{} = final), do: {final.status, final.reason}
  defp attempt_outcome(_attempt, %Event{trigger: trigger}, nil), do: {"failed", trigger}
  defp attempt_outcome(_attempt, _escalation, _final), do: {nil, nil}

  defp sum_tokens(rows) do
    names = ["input", "cached_input", "output", "reasoning"]

    Map.new(names, fn name ->
      total =
        Enum.reduce(rows, 0, fn row, total ->
          total + Map.get(row.tokens || %{}, name, 0)
        end)

      {name, total}
    end)
  end

  defp phase_timings(events) do
    for %Event{event: "phase_timing"} = event <- events do
      json_object([
        {"phase", event.phase},
        {"name", event.name},
        {"wall_ms", event.wall_ms},
        {"started_at", event.started_at},
        {"finished_at", event.finished_at}
      ])
    end
  end

  defp failures(events) do
    for %Event{event: "stage_failure"} = event <- events do
      json_object([
        {"stage", event.stage},
        {"class", event.class},
        {"reason", event.reason},
        {"detail", event.detail}
      ])
    end
  end

  defp findings(events) do
    for %Event{event: type} = event <- events, type in ["scope_warning", "landing_warning"] do
      json_object([
        {"type", type},
        {"path", event.path},
        {"declared_domains", nullable(event.declared_domains)},
        {"message", event.detail}
      ])
    end
  end

  defp last_gate(events) do
    case finished_event(events) do
      %Event{gate_summary: summary} when is_map(summary) -> summary
      _event -> nil
    end
  end

  defp candidate_diffs(%Run{} = run, events) do
    for %Event{event: "candidate_diff"} = event <- events do
      json_object([
        {"attempt", nullable(event.attempt)},
        {"reason", nullable(event.reason)},
        {"file", nullable(event.candidate_diff)},
        {"source_path", candidate_source(run, event.candidate_diff)},
        {"protected_paths_changed", event.excluded_paths || []},
        {"red_checks", event.red_checks || []},
        {"acceptance_items", event.acceptance_items || []},
        {"commit", nullable(event.commit)},
        {"metrics", nullable(event.metrics)}
      ])
    end
  end

  defp latest_candidate_value(events, key, default) do
    events
    |> Enum.reverse()
    |> Enum.find_value(default, fn
      %Event{event: "candidate_diff"} = event -> Map.get(event, key)
      _other -> nil
    end)
  end

  defp candidate_source(_run, nil), do: :null
  defp candidate_source(%Run{dir: dir}, filename), do: Path.join(dir, filename)

  defp stop(events) do
    case finished_event(events) do
      %Event{status: "failed", stop: stop} when is_map(stop) ->
        stop

      %Event{status: "failed", reason: reason, attempt: attempt} ->
        json_object([
          {"reason", nullable(reason)},
          {"reason_text", nullable(reason_text(reason))},
          {"attempt", nullable(attempt)},
          {"repair_cap", :null},
          {"repairs_used", :null},
          {"repairs_remaining", :null},
          {"failed_test_count", :null},
          {"check_count", :null},
          {"failed_check_count", :null},
          {"fix_count", :null},
          {"failed_fix_count", :null},
          {"finding_count", :null}
        ])

      _event ->
        nil
    end
  end

  defp finished_event(events), do: Enum.find(Enum.reverse(events), &(&1.event == "finished"))

  defp reason_text(nil), do: nil
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp excused_flakes(events) do
    for %Event{event: "flake_excused"} = event <- events do
      json_object([{"test_ids", event.test_ids}, {"seed", event.seed}])
    end
  end

  defp event_value(events, key) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&Map.get(&1, key))
  end

  defp event_payload(events, event_name, key, default) do
    events
    |> Enum.reverse()
    |> Enum.find_value(default, fn
      %Event{event: ^event_name} = event -> Map.get(event, key)
      _other -> nil
    end)
  end

  defp landing_value(%Run{landing: nil}, _key), do: nil
  defp landing_value(%Run{landing: landing}, :expected_parent), do: landing.expected_parent
  defp landing_value(%Run{landing: landing}, :candidate_commit), do: landing.candidate_commit

  defp json_object(pairs), do: Map.new(pairs)

  defp nullable(nil), do: :null
  defp nullable(value), do: value
end
