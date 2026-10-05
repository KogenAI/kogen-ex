defmodule Kogen.Engine.Build.Engine do
  @moduledoc false

  alias Kogen.Build.Cycle
  alias Kogen.Build.Recipe
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.Finish
  alias Kogen.Engine.Build.Prepared
  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Build.Result
  alias Kogen.Engine.Build.RunEvents
  alias Kogen.Engine.Build.Session
  alias Kogen.Engine.Build.Setup
  alias Kogen.Engine.Runtime
  alias Kogen.Intent
  alias Kogen.Proc.Sandbox
  alias Kogen.Project
  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.State.Run
  alias Kogen.Workspace

  @spec start(Request.t()) ::
          {:started, Session.t(), [term()]} | {:ok, Result.t()} | {:error, term()}
  def start(%Request{} = request) do
    with {:ok, approval_commit, approval} <- approved(request),
         {:ok, intent, intent_text} <- approved_intent(approval),
         {:ok, _project} <- Project.load(request.project_root),
         {:ok, run} <- State.start_run(state_root(request), approval) do
      prepare_run(%Prepared{
        request: request,
        run: run,
        approval: approval,
        approval_commit: approval_commit,
        intent: intent,
        intent_text: intent_text,
        base_sha: approval.base_sha
      })
    end
  end

  defp prepare_run(%Prepared{} = prepared) do
    request = prepared.request

    with {:ok, base, manifest, drift} <-
           Workspace.build_base(
             request.origin,
             request.base,
             prepared.approval,
             request.runtime.git_env
           ),
         :ok <- RunEvents.base_drift(prepared.run, drift, base) do
      approval = %{prepared.approval | protected_manifest: manifest}
      begin_run(%{prepared | base_sha: base, approval: approval})
    else
      {:error, reason} -> Finish.setup_failure(request, prepared.run, reason, false)
    end
  end

  defp begin_run(%Prepared{} = prepared) do
    case claim(prepared.request, prepared.run) do
      :ok ->
        case RunEvents.started(
               prepared.run,
               prepared.request,
               prepared.approval,
               prepared.approval_commit,
               prepared.base_sha
             ) do
          :ok ->
            setup_workspace(prepared)

          {:error, reason} ->
            Finish.setup_failure(
              prepared.request,
              prepared.run,
              {:state_start_failed, reason}
            )
        end

      {:error, reason} ->
        Finish.setup_failure(prepared.request, prepared.run, reason, false)
    end
  end

  defp approved(request) do
    ref = "refs/kogen/intents/#{request.slug}"

    with {:ok, commit} <- Workspace.ref_read(request.origin, ref, request.runtime.git_env),
         {:ok, approval} <- State.approval(request.origin, request.slug, request.runtime.git_env),
         true <- approval.target_branch == request.base do
      {:ok, commit, approval}
    else
      false -> {:error, :approval_branch_mismatch}
      {:error, :missing} -> {:error, :intent_not_approved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approved_intent(%Approval{} = approval) do
    path = ".kogen/intents/#{approval.slug}/intent.md"

    with {:ok, intent} <- Intent.parse_binary(approval.intent_bytes, path),
         true <- intent.slug == approval.slug,
         [] <- Intent.structural_issues(intent) do
      {:ok, intent, approval.intent_bytes}
    else
      false -> {:error, :approved_intent_slug_mismatch}
      {:error, issues} -> {:error, {:approved_intent_invalid, issues}}
      issues when is_list(issues) -> {:error, {:approved_intent_lint, issues}}
    end
  end

  defp claim(request, %Run{id: run_id}) do
    State.claim(request.origin, run_id, request.runtime.git_env)
  end

  defp setup_workspace(%Prepared{} = prepared) do
    request = prepared.request

    case Workspace.create(
           request.origin,
           prepared.base_sha,
           request.workspace_root,
           prepared.run.id,
           request.runtime.git_env,
           seed_from: request.project_root
         ) do
      {:ok, checkout} ->
        setup_candidate(prepared, checkout.path)

      {:error, reason} ->
        failed_setup(request, prepared.run, reason)
    end
  end

  # Resolve tools from the approved project root so home-directory configs do
  # not change the candidate toolchain; trust both paths through the environment.
  defp workspace_environment(path, project_root, runtime, project, run_dir) do
    runtime = Runtime.for_run(Runtime.add_trusted_workspace(runtime, project_root), run_dir)

    with {:ok, env} <- Kogen.Engine.candidate_environment(project_root, runtime, project) do
      {:ok, env |> Runtime.add_trusted_workspace(path) |> Runtime.for_run(run_dir)}
    end
  end

  defp setup_candidate(%Prepared{} = prepared, path) do
    request = prepared.request

    with :ok <-
           Workspace.install_intent_files(
             path,
             prepared.approval.slug,
             prepared.approval.intent_bytes,
             prepared.approval.acceptance_files
           ),
         {:ok, candidate_project} <- Project.load(path),
         {:ok, process_env} <-
           workspace_environment(
             path,
             request.project_root,
             request.runtime,
             candidate_project,
             prepared.run.dir
           ) do
      start_candidate(prepared, path, candidate_project, process_env)
    else
      {:error, {:toolchain_failed, detail}} ->
        failure = %Failure{class: :environment, reason: :toolchain_failed, detail: detail}
        fail_candidate_setup(request, prepared.run, path, failure)

      {:error, reason} ->
        fail_candidate_setup(request, prepared.run, path, reason)
    end
  end

  defp start_candidate(prepared, path, project, process_env) do
    session = candidate_session(prepared, path, project, process_env)

    case Setup.run_cached(session) do
      :ok ->
        start_cycle(session)

      {:error, reason} ->
        fail_candidate_setup(prepared.request, prepared.run, path, reason)
    end
  end

  defp candidate_session(prepared, path, project, process_env) do
    request = prepared.request

    ladder_start(
      %Session{
        request: request,
        approval: prepared.approval,
        approval_commit: prepared.approval_commit,
        intent: prepared.intent,
        intent_text: prepared.intent_text,
        project: project,
        run: prepared.run,
        sandbox: %Sandbox{
          enabled:
            project.sandbox and not Runtime.sandboxed?(process_env) and
              not Runtime.sandboxed?(request.runtime),
          home: request.home,
          project_root: request.project_root,
          origin: request.origin,
          workspace: path,
          run_dir: prepared.run.dir,
          tmp_dir: Runtime.temporary_directory(process_env)
        },
        cycle: Cycle.new(%{approval: prepared.approval, repairs: 2, recipe: request.recipe}),
        state_root: state_root(request),
        run_dir: prepared.run.dir,
        base_sha: prepared.base_sha,
        workdir: path,
        process_env: process_env,
        git_env: Runtime.git_environment(process_env),
        receipts: [],
        acceptance: []
      },
      request.recipe
    )
  end

  # A ladder starts on its first rung, and its wall budget covers the whole Build.
  defp ladder_start(session, recipe) do
    now = System.monotonic_time(:millisecond)

    case Recipe.ladder(recipe) do
      %{wall_ms: wall_ms} ->
        %{
          session
          | rung: Recipe.rung(recipe, 0),
            budget_deadline: now + wall_ms,
            rung_started_at: now
        }

      nil ->
        session
    end
  end

  defp fail_candidate_setup(request, run, path, reason) do
    case Workspace.destroy(path) do
      :ok -> failed_setup(request, run, reason)
      {:error, cleanup} -> failed_setup(request, run, {:setup_cleanup_failed, reason, cleanup})
    end
  end

  defp start_cycle(session) do
    {cycle, effects} = Cycle.step(session.cycle, :start)
    {:started, %{session | cycle: cycle}, effects}
  end

  defp failed_setup(request, run, reason), do: Finish.setup_failure(request, run, reason)

  defp state_root(request), do: request.workspace_root
end
