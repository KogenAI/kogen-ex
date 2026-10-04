defmodule Kogen.Kernel.Report do
  @moduledoc false

  alias Kogen.Kernel.StateView
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
         status = State.status(origin, state_root, slug, base, git_env),
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
    report =
      json_object([
        {"slug", run.slug},
        {"status", Atom.to_string(status)},
        {"recipe", nullable(event_value(events, :recipe))},
        {"roles", event_value(events, :roles) || %{}},
        {"approval", nullable(run.approval_commit)},
        {"base",
         nullable(event_value(events, :base_sha) || landing_value(run, :expected_parent))},
        {"candidate", nullable(landing_value(run, :candidate_commit))},
        {"landed_sha", nullable(landed_sha)},
        {"credential",
         json_object([
           {"source", nullable(event_value(events, :credential_source))},
           {"label", nullable(event_value(events, :credential_label))}
         ])},
        {"acceptance_results", event_payload(events, "acceptance_result", :ledger, [])},
        {"check_receipts", event_payload(events, "check_result", :receipts, [])},
        {"excused_flakes", excused_flakes(events)},
        {"model_stages", model_stages(events)},
        {"phase_timings", phase_timings(events)},
        {"findings", findings(events)},
        {"failures", failures(events)}
      ])

    {:ok, report |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ArgumentError -> {:error, :report_encoding_failed}
  end

  defp model_stages(events) do
    for %Event{event: "model_stage"} = event <- events do
      json_object([
        {"stage", event.stage},
        {"model", event.model},
        {"effort", event.effort},
        {"tokens", event.tokens},
        {"wall_ms", event.wall_ms}
      ])
    end
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
    for %Event{event: "scope_warning"} = event <- events do
      json_object([
        {"type", "scope_warning"},
        {"path", event.path},
        {"declared_domains", event.declared_domains},
        {"message", event.detail}
      ])
    end
  end

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
