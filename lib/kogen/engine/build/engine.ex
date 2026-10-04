defmodule Kogen.Engine.Build.Engine do
  @moduledoc false

  alias Kogen.Build.Cycle
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.ApprovalManifest
  alias Kogen.Engine.Build.Escalation
  alias Kogen.Engine.Build.Finish
  alias Kogen.Engine.Build.Prepared
  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Build.Result
  alias Kogen.Engine.Build.RunEvents
  alias Kogen.Engine.Build.Session
  alias Kogen.Engine.Build.Setup
  alias Kogen.Engine.Build.StageRunner
  alias Kogen.Engine.Runtime
  alias Kogen.Proc.Sandbox
  alias Kogen.Project
  alias Kogen.State
  alias Kogen.State.Approval
  alias Kogen.State.Run
  alias Kogen.Workspace

  @spec run(Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Request{} = request) do
    with {:ok, approval_commit, approval} <- approved(request),
         {:ok, base_sha} <- current_base(request, approval),
         {:ok, intent, intent_text} <- approved_intent(approval),
         {:ok, _project} <- Project.load(request.project_root),
         {:ok, run} <- State.start_run(state_root(request), approval) do
      begin_run(%Prepared{
        request: request,
        run: run,
        approval: approval,
        approval_commit: approval_commit,
        intent: intent,
        intent_text: intent_text,
        base_sha: base_sha
      })
    end
  end

  defp begin_run(%Prepared{} = prepared) do
    case claim(prepared.request, prepared.run) do
      :ok ->
        case RunEvents.started(
               prepared.run,
               prepared.request,
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

  defp current_base(request, %Approval{} = approval) do
    approved_sha = approval.base_sha

    case Workspace.ref_read(request.origin, "refs/heads/#{request.base}", request.runtime.git_env) do
      {:ok, ^approved_sha} ->
        {:ok, approved_sha}

      {:ok, current} ->
        with true <-
               Workspace.ancestor?(request.origin, approved_sha, current, request.runtime.git_env),
             :ok <-
               ApprovalManifest.unchanged_between(
                 request.origin,
                 approved_sha,
                 current,
                 approval.protected_manifest,
                 request.runtime.git_env
               ) do
          {:ok, current}
        else
          false -> {:error, {:base_moved, approved_sha, current}}
          {:error, reason} -> {:error, reason}
        end

      {:error, :missing} ->
        {:error, {:base_moved, approved_sha, nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp approved_intent(%Approval{} = approval) do
    path = ".kogen/intents/#{approval.slug}/intent.md"

    with {:ok, intent} <- Kogen.Intent.parse_binary(approval.intent_bytes, path),
         true <- intent.slug == approval.slug,
         [] <- Kogen.Intent.lint(intent) do
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

  # Trust the exact workspace path; do not write a global mise trust entry.
  defp workspace_environment(path, runtime, project, run_dir) do
    runtime = Runtime.for_run(Runtime.trust_workspace(runtime, path), run_dir)

    with {:ok, env} <- Kogen.Engine.candidate_environment(path, runtime, project) do
      {:ok, env |> Runtime.trust_workspace(path) |> Runtime.for_run(run_dir)}
    end
  end

  defp setup_candidate(%Prepared{} = prepared, path) do
    request = prepared.request

    with :ok <- Workspace.insert_files(path, approved_files(prepared.approval)),
         {:ok, candidate_project} <- Project.load(path),
         {:ok, process_env} <-
           workspace_environment(path, request.runtime, candidate_project, prepared.run.dir) do
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
      cycle:
        Cycle.new(%{
          approval: prepared.approval,
          repairs: 2,
          recipe: request.recipe
        }),
      state_root: state_root(request),
      run_dir: prepared.run.dir,
      base_sha: prepared.base_sha,
      workdir: path,
      process_env: process_env,
      git_env: Runtime.git_environment(process_env),
      receipts: [],
      acceptance: []
    }
  end

  defp fail_candidate_setup(request, run, path, reason) do
    case Workspace.destroy(path) do
      :ok -> failed_setup(request, run, reason)
      {:error, cleanup} -> failed_setup(request, run, {:setup_cleanup_failed, reason, cleanup})
    end
  end

  defp approved_files(%Approval{} = approval) do
    acceptance_path = ".kogen/acceptance/#{approval.slug}_test.exs"
    acceptance = Map.fetch!(approval.acceptance_files, acceptance_path)

    %{
      ".kogen/intents/#{approval.slug}/intent.md" => approval.intent_bytes,
      acceptance_path => acceptance,
      "test/acceptance/#{approval.slug}_test.exs" => acceptance
    }
  end

  defp start_cycle(session) do
    {cycle, effects} = Cycle.step(session.cycle, :start)
    finish_drive(run_effects(%{session | cycle: cycle}, effects))
  end

  defp finish_drive({:done, result}), do: result

  defp finish_drive({:continue, session}) do
    case finish_if_terminal(session) do
      {:done, result} -> result
      {:continue, _session} -> {:error, :cycle_incomplete}
    end
  end

  defp run_events(session, []), do: finish_if_terminal(session)

  defp run_events(session, [event | rest]) do
    case apply_event(session, event) do
      {:continue, updated} -> run_events(updated, rest)
      {:done, result} -> {:done, result}
    end
  end

  defp apply_event(session, event) do
    {cycle, effects} = Cycle.step(session.cycle, event)
    run_effects(%{session | cycle: cycle}, effects)
  end

  defp run_effects(session, []), do: finish_if_terminal(session)

  defp run_effects(session, [{:record, event} | rest]) do
    case State.record(session.run, event) do
      :ok ->
        session = add_record_line(session, event)
        continue_effects(session, rest)

      {:error, reason} ->
        controller = %Failure{
          class: :controller,
          reason: :state_write_failed,
          detail: inspect(reason)
        }

        result = terminal_failure(session, controller)
        {:done, result}
    end
  end

  defp run_effects(session, [{:run, stage, args} | rest]) do
    case StageRunner.run(stage, args, session) do
      {:ok, updated, events} ->
        updated = add_stage_line(updated, stage, events)
        run_events_with_tail(updated, events, rest)

      {:error, updated, failure} ->
        updated = add_stage_line(updated, stage, [{:stage_failed, stage, failure}])
        apply_effect_event(updated, {:stage_failed, stage, failure}, rest)

      {:base_moved, updated} ->
        apply_effect_event(updated, {:base_moved}, rest)
    end
  end

  defp run_effects(session, [{:escalate, _args} | rest]) do
    case Escalation.reset_candidate(session) do
      {:ok, updated} -> run_effects(updated, rest)
      {:error, updated, failure} -> escalate_setup_failed(updated, failure, rest)
    end
  end

  defp run_effects(session, [{:finish, status, reason} | _rest]) do
    {:done, finish(session, status, reason)}
  end

  defp run_events_with_tail(session, events, tail) do
    case run_events(session, events) do
      {:continue, updated} -> run_effects(updated, tail)
      {:done, result} -> {:done, result}
    end
  end

  defp apply_effect_event(session, event, tail) do
    case apply_event(session, event) do
      {:continue, updated} -> run_effects(updated, tail)
      {:done, result} -> {:done, result}
    end
  end

  defp continue_effects(session, rest) do
    case run_effects(session, rest) do
      {:continue, updated} -> {:continue, updated}
      {:done, result} -> {:done, result}
    end
  end

  defp escalate_setup_failed(session, failure, rest),
    do: apply_effect_event(session, {:stage_failed, :develop, failure}, rest)

  defp finish_if_terminal(session) do
    case session.cycle.result do
      {status, reason} -> {:done, finish(session, status, reason)}
      nil -> {:continue, session}
    end
  end

  defp finish(session, status, reason), do: Finish.run(session, status, reason)

  defp add_stage_line(session, stage, events) do
    session = %{session | lines: session.lines ++ [stage_line(stage, events, session)]}

    case events do
      [{:stage_failed, _stage, failure}] ->
        %{session | failure: failure, failure_text: failure.detail}

      _events ->
        session
    end
  end

  defp stage_line(:context, _events, _session), do: "context: complete"
  defp stage_line(:plan, _events, _session), do: "plan: complete"
  defp stage_line(:fix, _events, _session), do: "fix: complete"
  defp stage_line(:check, _events, _session), do: "checks + acceptance: pass"
  defp stage_line(:review, [{:review, verdict, _findings}], _session), do: "review: #{verdict}"
  defp stage_line(:develop, events, _session), do: "develop: #{develop_outcome(events)}"

  defp stage_line(:commit, [{:stage_ok, :commit, data}], _session),
    do: "commit: #{Map.get(data, :candidate_commit, "complete")}"

  defp stage_line(:land, _events, _session), do: "land: complete"
  defp stage_line(stage, _events, _session), do: "#{stage}: complete"

  defp develop_outcome([_first, {:stage_ok, :done_gate, %{outcome: outcome}}]), do: outcome
  defp develop_outcome(_events), do: :complete

  defp add_record_line(session, %{event: :repair, reason: reason}),
    do: %{session | lines: session.lines ++ ["repair: #{reason}"]}

  defp add_record_line(session, _event), do: session

  defp terminal_failure(session, failure), do: Finish.terminal_failure(session, failure)
  defp failed_setup(request, run, reason), do: Finish.setup_failure(request, run, reason)

  defp state_root(request), do: request.workspace_root
end
