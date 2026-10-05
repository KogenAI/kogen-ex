defmodule Kogen.Engine.Build.Finish do
  @moduledoc false

  alias Kogen.Build.GateSummary
  alias Kogen.Build.Selector
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.CandidateSnapshot
  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Build.Result
  alias Kogen.Engine.Build.Session
  alias Kogen.State
  alias Kogen.State.Run
  alias Kogen.Workspace

  @spec run(Session.t(), :landed | :failed | :parked, term()) :: {:ok, Result.t()}
  def run(%Session{} = session, status, reason) do
    case prepare(session, status, reason) do
      {:ok, session} ->
        finish(session, status, reason)

      {:error, detail} ->
        terminal_failure(
          session,
          %Failure{
            class: :controller,
            reason: :candidate_snapshot_failed,
            detail: inspect(detail)
          }
        )
    end
  end

  defp prepare(%Session{rung: nil} = session, status, reason) do
    case CandidateSnapshot.before_finish(session, status, reason) do
      :ok -> {:ok, session}
      {:error, detail} -> {:error, detail}
    end
  end

  # A failed ladder Build keeps its last Candidate for the selector. Snapshot trouble must
  # not hide the Build's own outcome.
  defp prepare(%Session{} = session, :failed, reason) do
    case CandidateSnapshot.record(session, reason, :keep) do
      {:ok, recorded} ->
        {:ok, recorded}

      {:error, detail} ->
        _recorded = State.record(session.run, %{event: :cleanup_failure, detail: inspect(detail)})
        {:ok, session}
    end
  end

  defp prepare(%Session{} = session, _status, _reason), do: {:ok, session}

  defp finish(%Session{} = session, status, reason) do
    preserve = preserve_candidate(session, status)
    session = if preserve == :ok, do: publish_best(session, status), else: session
    release = release_claim(session)
    lifecycle = cleanup_result(preserve, release)
    write_result = write_cleanup_failure(session, lifecycle)
    failure = final_failure(session.failure, lifecycle, write_result)

    {:ok,
     %Result{
       status: status,
       reason: reason,
       failure: failure,
       run_id: session.run.id,
       run_dir: session.run_dir,
       landed_sha: landed_sha(status, session, reason),
       lines: session.lines ++ [finish_line(status, reason, lifecycle)]
     }}
  end

  @spec terminal_failure(Session.t(), Failure.t()) :: {:ok, Result.t()}
  def terminal_failure(%Session{} = session, %Failure{} = failure) do
    record =
      State.record(session.run, %{
        event: :finished,
        status: :failed,
        reason: failure.reason,
        attempt: session.attempt,
        gate_summary: GateSummary.compact(session.last_harness && session.last_harness.gate),
        stop: failure_stop(failure, session.attempt)
      })

    preserve = preserve_candidate(session, :failed)
    release = release_claim(session)
    final = terminal_cleanup_failure(failure, record, preserve, release)

    {:ok,
     %Result{
       status: :failed,
       reason: final.reason,
       failure: final,
       run_id: session.run.id,
       run_dir: session.run_dir,
       landed_sha: nil,
       lines: session.lines ++ ["build: failed (#{final.class}/#{final.reason})"]
     }}
  end

  @spec setup_failure(Request.t(), Run.t(), term()) :: {:ok, Result.t()}
  def setup_failure(%Request{} = request, %Run{} = run, reason) do
    setup_failure(request, run, reason, true)
  end

  @spec setup_failure(Request.t(), Run.t(), term(), boolean()) :: {:ok, Result.t()}
  def setup_failure(%Request{} = request, %Run{} = run, reason, claimed?) do
    failure = normalize_setup_failure(reason)

    first =
      State.record(run, %{
        event: :stage_failure,
        stage: :setup,
        class: failure.class,
        reason: failure.reason,
        detail: failure.detail
      })

    terminal =
      State.record(run, %{
        event: :finished,
        status: :failed,
        reason: failure.reason,
        attempt: :builder,
        stop: failure_stop(failure, :builder)
      })

    release = release_setup_claim(request, run, claimed?)
    failure = persistence_failure(failure, combine(first, terminal), release)

    {:ok,
     %Result{
       status: :failed,
       reason: failure.reason,
       failure: failure,
       run_id: run.id,
       run_dir: run.dir,
       landed_sha: nil,
       lines: ["setup: failed (#{failure.class}/#{failure.reason}): #{failure.detail}"]
     }}
  end

  defp preserve_candidate(%Session{workdir: workdir}, :landed), do: Workspace.destroy(workdir)

  defp preserve_candidate(%Session{} = session, _status) do
    with :ok <- commit_uncommitted(session),
         :ok <-
           Workspace.park(
             session.workdir,
             session.request.origin,
             session.run.id,
             session.git_env
           ) do
      :ok
    else
      {:error, reason} -> {:error, {:candidate_kept_at, session.workdir, reason}}
    end
  end

  defp commit_uncommitted(session), do: CandidateSnapshot.commit_tree(session)

  # With no green rung, the best Candidate is pushed to `kogen/<slug>` for a human to finish.
  defp publish_best(%Session{rung: %{}, candidates: [_ | _] = candidates} = session, :failed) do
    best = Selector.best(candidates)
    branch = "kogen/" <> session.approval.slug

    case Workspace.publish_branch(session.request.origin, branch, best.commit, session.git_env) do
      :ok ->
        _recorded =
          State.record(
            session.run,
            Map.merge(Map.take(best, [:attempt, :commit, :metrics, :failing, :findings]), %{
              event: :best_candidate,
              branch: branch,
              reason: best.reason
            })
          )

        %{session | lines: session.lines ++ ["build: needs attention: #{branch}"]}

      {:error, reason} ->
        _recorded = State.record(session.run, %{event: :cleanup_failure, detail: inspect(reason)})
        session
    end
  end

  defp publish_best(session, _status), do: session

  defp release_claim(session) do
    State.release(session.request.origin, session.run.id, session.git_env)
  end

  defp cleanup_result(:ok, :ok), do: :ok
  defp cleanup_result(preserve, release), do: {:error, %{preserve: preserve, release: release}}

  defp write_cleanup_failure(_session, :ok), do: :ok

  defp write_cleanup_failure(session, {:error, detail}) do
    State.record(session.run, %{event: :cleanup_failure, detail: detail})
  end

  defp final_failure(failure, :ok, :ok), do: failure

  defp final_failure(failure, cleanup, write) do
    %Failure{
      class: :controller,
      reason: :cleanup_failed,
      detail:
        "cleanup=#{inspect(cleanup)} state_record=#{inspect(write)} prior=#{inspect(failure)}"
    }
  end

  defp persistence_failure(failure, :ok, :ok), do: failure

  defp persistence_failure(failure, record, release) do
    %Failure{
      class: :controller,
      reason: :state_finalize_failed,
      detail: "record=#{inspect(record)} release=#{inspect(release)} prior=#{inspect(failure)}"
    }
  end

  defp terminal_cleanup_failure(failure, :ok, :ok, :ok), do: failure

  defp terminal_cleanup_failure(failure, record, preserve, release) do
    %Failure{
      class: :controller,
      reason: :state_finalize_failed,
      detail:
        "record=#{inspect(record)} preserve=#{inspect(preserve)} release=#{inspect(release)} prior=#{inspect(failure)}"
    }
  end

  defp release_setup_claim(_request, _run, false), do: :ok

  defp release_setup_claim(request, run, true),
    do: State.release(request.origin, run.id, request.runtime.git_env)

  defp combine(:ok, result), do: result
  defp combine(result, :ok), do: result
  defp combine(first, second), do: {:error, {first, second}}

  defp landed_sha(:landed, session, reason) when is_binary(reason),
    do: session.landed_sha || reason

  defp landed_sha(_status, _session, _reason), do: nil

  defp failure_stop(failure, attempt) do
    %{
      reason: failure.reason,
      reason_text: reason_text(failure.reason),
      class: failure.class,
      attempt: attempt,
      repair_cap: 0,
      repairs_used: 0,
      repairs_remaining: 0,
      failed_test_count: nil,
      check_count: 0,
      failed_check_count: 0,
      fix_count: 0,
      failed_fix_count: 0,
      finding_count: 0
    }
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp finish_line(:landed, sha, :ok), do: "land: landed #{sha}"
  defp finish_line(:parked, reason, :ok), do: "build: parked (#{inspect(reason)})"
  defp finish_line(:failed, reason, :ok), do: "build: failed (#{inspect(reason)})"

  defp finish_line(_status, reason, {:error, detail}),
    do: "build: cleanup failed (#{inspect(detail)}; #{inspect(reason)})"

  defp normalize_setup_failure(%Failure{} = failure), do: failure

  defp normalize_setup_failure({:base_moved, _expected, _current}),
    do: %Failure{
      class: :environment,
      reason: :base_moved,
      detail: "Approved base changed; approve the Intent again."
    }

  defp normalize_setup_failure({:approved_protected_file_changed, path}),
    do: %Failure{
      class: :candidate,
      reason: :approved_acceptance_changed,
      detail: "Approved acceptance test #{path} changed on the base after approval."
    }

  defp normalize_setup_failure(:intent_not_approved),
    do: %Failure{
      class: :environment,
      reason: :not_approved,
      detail: "Intent has no approval ref."
    }

  defp normalize_setup_failure({:claimed, run_id}),
    do: %Failure{
      class: :environment,
      reason: :build_already_claimed,
      detail: "Another Build holds the project claim (run #{run_id})."
    }

  defp normalize_setup_failure(reason),
    do: %Failure{class: :controller, reason: :setup_failed, detail: inspect(reason)}
end
