defmodule Kogen.Engine.Build.Escalation do
  @moduledoc false

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
    case CandidateSnapshot.before_escalation(session, reason) do
      :ok ->
        reset_candidate_from_base(session)

      {:error, detail} ->
        {:error, session,
         %Failure{class: :controller, reason: :candidate_snapshot_failed, detail: inspect(detail)}}
    end
  end

  defp reset_candidate_from_base(%Session{} = session) do
    build_id = session.run.id <> "-escalation"

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
    with :ok <- Workspace.insert_files(path, approved_files(session.approval)),
         {:ok, project} <- Project.load(path),
         {:ok, process_env} <- candidate_environment(path, session, project),
         sandbox = %{
           session.sandbox
           | workspace: path,
             tmp_dir: Runtime.temporary_directory(process_env)
         },
         :ok <- Setup.run(project.setup, path, session.run_dir, process_env, Kogen.Proc, sandbox),
         :ok <- Workspace.destroy(session.workdir) do
      {:ok,
       %{
         session
         | workdir: path,
           project: project,
           process_env: process_env,
           git_env: Runtime.git_environment(process_env),
           sandbox: sandbox,
           harness_opts: nil,
           pack: nil,
           plan: nil,
           last_harness: nil,
           failure: nil,
           failure_text: nil,
           attempt: :escalation,
           direct_preflight_complete?: false,
           flake_excused: [],
           scope_warnings: [],
           receipts: [],
           acceptance: []
       }}
    else
      {:error, %Failure{} = reason} ->
        cleanup_candidate(path, session, reason)

      {:error, reason} ->
        cleanup_candidate(path, session, failure(:escalation_setup_failed, reason))
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

  defp approved_files(approval) do
    acceptance_path = ".kogen/acceptance/#{approval.slug}_test.exs"
    acceptance = Map.fetch!(approval.acceptance_files, acceptance_path)

    %{
      ".kogen/intents/#{approval.slug}/intent.md" => approval.intent_bytes,
      acceptance_path => acceptance,
      "test/acceptance/#{approval.slug}_test.exs" => acceptance
    }
  end

  defp failure(reason, detail),
    do: %Failure{class: :environment, reason: reason, detail: inspect(detail)}
end
