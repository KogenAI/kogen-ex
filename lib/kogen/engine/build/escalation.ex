defmodule Kogen.Engine.Build.Escalation do
  @moduledoc false

  alias Kogen.Build.Demotion
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.CandidateSnapshot
  alias Kogen.Engine.Build.Session
  alias Kogen.Engine.Build.Setup
  alias Kogen.Engine.Runtime
  alias Kogen.Project
  alias Kogen.State
  alias Kogen.Workspace

  @spec reset_candidate(Session.t()) :: {:ok, Session.t()} | {:error, Session.t(), Failure.t()}
  def reset_candidate(%Session{} = session), do: reset_candidate(session, nil)

  @spec reset_candidate(Session.t(), term()) ::
          {:ok, Session.t()} | {:error, Session.t(), Failure.t()}
  def reset_candidate(%Session{} = session, reason) do
    with :ok <- snapshot(session, reason),
         {:ok, fresh} <- fresh_candidate(session, session.run.id <> "-escalation"),
         :ok <- destroy_previous(fresh, session.workdir) do
      {:ok, %{fresh | attempt: :escalation}}
    end
  end

  @doc """
  A new Candidate checkout of the approved base with the approved Intent files, setup run, and
  any demoted acceptance items excluded. The previous checkout is left alone.
  """
  @spec fresh_candidate(Session.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Session.t(), Failure.t()}
  def fresh_candidate(%Session{} = session, build_id) do
    case Workspace.create(
           session.request.origin,
           session.base_sha,
           session.request.workspace_root,
           build_id,
           session.git_env,
           seed_from: session.request.project_root
         ) do
      {:ok, %{path: path}} ->
        prepare_new_candidate(session, path)

      {:error, reason} ->
        {:error, session, record_failure(session, failure(:candidate_checkout_failed, reason))}
    end
  end

  defp prepare_new_candidate(session, path) do
    approval = session.approval

    with :ok <-
           Workspace.install_intent_files(
             path,
             approval.slug,
             approval.intent_bytes,
             approval.acceptance_files
           ),
         {:ok, project} <- Project.load(path),
         {:ok, process_env} <- candidate_environment(path, session, project),
         fresh = fresh_session(session, path, project, process_env),
         :ok <- Setup.run_cached(fresh) do
      {:ok, fresh}
    else
      {:error, %Failure{} = reason} ->
        cleanup_candidate(path, session, reason)

      {:error, reason} ->
        cleanup_candidate(path, session, failure(:escalation_setup_failed, reason))
    end
  end

  defp fresh_session(session, path, project, process_env) do
    demoted = Enum.map(session.demoted, & &1.id)

    %{
      session
      | workdir: path,
        project: Demotion.exclude(project, session.approval.slug, demoted),
        process_env: process_env,
        git_env: Runtime.git_environment(process_env),
        sandbox: %{
          session.sandbox
          | workspace: path,
            tmp_dir: Runtime.temporary_directory(process_env)
        },
        harness_opts: nil,
        pack: nil,
        plan: nil,
        last_harness: nil,
        failure: nil,
        failure_text: nil,
        direct_preflight_complete?: false,
        flake_excused: [],
        scope_warnings: [],
        receipts: [],
        acceptance: [],
        acceptance_failures: []
    }
  end

  defp snapshot(session, reason) do
    case CandidateSnapshot.before_escalation(session, reason) do
      :ok ->
        :ok

      {:error, detail} ->
        {:error, session,
         %Failure{class: :controller, reason: :candidate_snapshot_failed, detail: inspect(detail)}}
    end
  end

  defp destroy_previous(fresh, previous) do
    case Workspace.destroy(previous) do
      :ok ->
        :ok

      {:error, reason} ->
        cleanup_candidate(fresh.workdir, fresh, failure(:cleanup_failed, reason))
    end
  end

  defp candidate_environment(path, session, project) do
    runtime =
      session.request.runtime
      |> Runtime.trust_workspace(path)
      |> Runtime.for_run(session.run_dir)

    with {:ok, env} <- Kogen.Engine.candidate_environment(path, runtime, project) do
      {:ok, env |> Runtime.trust_workspace(path) |> Runtime.for_run(session.run_dir)}
    end
  end

  defp cleanup_candidate(path, session, %Failure{} = failure) do
    case Workspace.destroy(path) do
      :ok ->
        {:error, session, record_failure(session, failure)}

      {:error, reason} ->
        cleanup_failure = %Failure{
          class: :controller,
          reason: :cleanup_failed,
          detail: inspect(reason)
        }

        {:error, session, record_failure(session, cleanup_failure)}
    end
  end

  defp record_failure(session, %Failure{} = failure) do
    case State.record(session.run, %{
           event: :stage_failure,
           stage: :escalation_setup,
           class: failure.class,
           reason: failure.reason,
           detail: failure.detail
         }) do
      :ok ->
        failure

      {:error, reason} ->
        %Failure{class: :controller, reason: :state_write_failed, detail: inspect(reason)}
    end
  end

  defp failure(reason, detail),
    do: %Failure{class: :environment, reason: reason, detail: inspect(detail)}
end
