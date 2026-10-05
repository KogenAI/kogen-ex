defmodule Kogen.Runner.Landing do
  @moduledoc false

  # Landing repairs belong to the winning builder conversation, with their own ten-minute
  # allowance. They never re-plan, escalate to a new rung, or release the Build's claim.
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Redact
  alias Kogen.Engine.Build.Commit
  alias Kogen.Engine.Build.Session
  alias Kogen.Engine.Build.StageRunner
  alias Kogen.State

  @allowance_ms 600_000

  @spec prepare(Session.t()) :: term()
  def prepare(session) do
    session = start_allowance(session)
    bounded(session, fn -> prepared(Commit.run(session)) end)
  end

  defp prepared({:error, _session, %Failure{reason: :approved_acceptance_changed}} = result),
    do: result

  defp prepared({:error, session, %Failure{class: :candidate} = failure}),
    do: repair(%{session | landing_verdict: :red}, failure)

  defp prepared({:ok, session, events}), do: {:ok, %{session | landing_verdict: :green}, events}
  defp prepared(result), do: result

  @spec land(map(), Session.t()) :: term()
  def land(identity, session) do
    bounded(session, fn ->
      case retry_land(identity, session, [1_000, 2_000, 4_000]) do
        {:ok, warnings} -> landed(session, identity.candidate_commit, warnings)
        {:error, reason} when reason in [:base_moved, :ref_locked] -> reland(session)
        {:error, reason} -> landing_failure(session, reason)
      end
    end)
  end

  defp reland(session) do
    case prepared(Commit.run(session, true)) do
      {:ok, updated, [{:stage_ok, :commit, identity}]} ->
        case State.put_landing(updated.run, identity) do
          :ok -> land_after_refresh(identity, updated)
          {:error, reason} -> landing_failure(updated, {:landing_record, reason})
        end

      result ->
        result
    end
  end

  defp land_after_refresh(identity, session) do
    case workspace_land(identity, session) do
      {:ok, warnings} -> landed(session, identity.candidate_commit, warnings)
      {:error, :base_moved} -> land(identity, session)
      {:error, :ref_locked} -> park_failed(session, :ref_locked)
      {:error, reason} -> landing_failure(session, reason)
    end
  end

  defp retry_land(identity, session, waits) do
    case workspace_land(identity, session) do
      {:error, reason} when reason in [:base_moved, :ref_locked] and waits != [] ->
        retry_after(identity, session, waits, reason)

      result ->
        result
    end
  end

  defp retry_after(identity, session, [wait | rest], reason) do
    event = %{
      event: :landing_retry,
      stage: :land,
      reason: reason,
      name: Integer.to_string(4 - length([wait | rest])),
      attempt: session.attempt,
      wall_ms: wait
    }

    case State.record(session.run, event) do
      :ok ->
        receive do
        after
          min(wait, remaining(session)) -> :ok
        end

        retry_land(identity, session, rest)

      {:error, detail} ->
        {:error, {:state_write_failed, detail}}
    end
  end

  defp park_failed(session, reason) do
    case landing_failure(session, reason) do
      {:error, updated, %Failure{class: :environment}} -> {:parked, updated, :landing_failed}
      result -> result
    end
  end

  defp repair(session, failure) do
    with true <- remaining(session) > 0,
         {:ok, before} <- Commit.tree_hash(session),
         :ok <- record_repair(session, failure) do
      session = %{
        session
        | failure: failure,
          failure_text: failure.detail,
          lines: session.lines ++ ["repair: landing #{failure.reason}"]
      }

      case repair_stages(session) do
        {:ok, updated} -> prepared(Commit.run(updated))
        {:error, updated, next} -> retry_repair(updated, next, before)
      end
    else
      false -> parked(session)
      {:error, _reason} -> parked(session)
    end
  end

  defp retry_repair(session, failure, before) do
    case Commit.tree_hash(session) do
      {:ok, tree} when tree != before and failure.class == :candidate ->
        repair(session, failure)

      _impossible ->
        parked(%{session | failure: failure, failure_text: failure.detail, landing_verdict: :red})
    end
  end

  defp repair_stages(session) do
    with {:ok, developed, _events} <- StageRunner.run(:develop, %{landing: true}, session),
         :ok <- green(developed),
         {:ok, fixed, _events} <- StageRunner.run(:fix, %{}, developed),
         {:ok, checked, _events} <- StageRunner.run(:check, %{}, fixed),
         {:ok, reviewed, [{:review, verdict, findings}]} <- StageRunner.run(:review, %{}, checked) do
      if verdict == :accept,
        do: {:ok, reviewed},
        else: {:error, reviewed, candidate(:review_revise, Enum.join(findings, "\n"))}
    else
      {:error, %Session{}, %Failure{}} = result ->
        result

      {:red, updated} ->
        {:error, updated,
         updated.failure ||
           candidate(:verification_failed, updated.failure_text || "Landing gate is red.")}
    end
  end

  defp green(%Session{last_harness: %{outcome: :done}}), do: :ok
  defp green(session), do: {:red, session}

  defp record_repair(session, failure) do
    State.record(session.run, %{
      event: :repair,
      stage: :land,
      reason: failure.reason,
      detail: failure.detail,
      attempt: session.attempt
    })
  end

  defp start_allowance(%Session{landing_deadline: nil} = session),
    do: %{session | landing_deadline: System.monotonic_time(:millisecond) + @allowance_ms}

  defp start_allowance(session), do: session

  defp remaining(session),
    do: max(session.landing_deadline - System.monotonic_time(:millisecond), 0)

  defp bounded(session, operation) do
    task = Task.async(operation)

    case Task.yield(task, remaining(session)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout -> parked(session)
    end
  end

  defp parked(session), do: {:base_moved, session}

  defp workspace_land(identity, session), do: Commit.land(identity, session)

  defp landed(session, sha, warnings) do
    session =
      Enum.reduce(warnings, session, fn %{path: path, detail: detail}, acc ->
        _recorded = State.record(acc.run, %{event: :landing_warning, path: path, detail: detail})
        IO.write(:stderr, Redact.text("land: warning: #{detail}\n"))
        %{acc | lines: acc.lines ++ ["land: warning: #{detail}"]}
      end)

    {:ok, %{session | landed_sha: sha}, [{:landed, sha}]}
  end

  defp landing_failure(session, reason) do
    class = landing_class(reason)

    failure = %Failure{
      class: class,
      reason: :landing_failed,
      detail: "landing failed (#{class}): #{inspect(reason)}"
    }

    event = %{
      event: :stage_failure,
      stage: :land,
      class: class,
      reason: failure.reason,
      detail: failure.detail
    }

    failure =
      case State.record(session.run, event) do
        :ok ->
          failure

        {:error, detail} ->
          %Failure{class: :controller, reason: :state_write_failed, detail: inspect(detail)}
      end

    {:error, %{session | failure: failure, failure_text: failure.detail}, failure}
  end

  defp landing_class({:state_write_failed, _detail}), do: :controller

  defp landing_class(reason) when reason in [:tree_mismatch, :not_fast_forward, :missing_head],
    do: :controller

  defp landing_class(_reason), do: :environment

  defp candidate(reason, detail), do: %Failure{class: :candidate, reason: reason, detail: detail}
end
