defmodule Kogen.Engine.Build.Commit do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.CheckStage
  alias Kogen.Engine.Build.Guard
  alias Kogen.Engine.Build.Session
  alias Kogen.State
  alias Kogen.Workspace

  @spec run(Session.t(), boolean()) ::
          {:ok, Session.t(), [term()]}
          | {:error, Session.t(), Failure.t()}
          | {:base_moved, Session.t()}
  def run(%Session{} = session, force_check \\ false) do
    State.measure_phase(session.run, "build", "commit", fn -> do_run(session, force_check) end)
  end

  @spec land(map(), Session.t()) :: {:ok, [map()]} | {:error, term()}
  def land(identity, session) do
    State.measure_phase(session.run, "build", "land", fn ->
      Workspace.land(
        session.workdir,
        session.request.origin,
        session.request.base,
        identity.expected_parent,
        session.run.id,
        session.git_env
      )
    end)
  end

  @spec tree_hash(Session.t()) :: {:ok, String.t()} | {:error, term()}
  def tree_hash(session), do: Guard.tree_hash(session.workdir, session.git_env)

  defp do_run(session, force_check) do
    with :ok <- guard(session),
         :ok <- tag(:squash, squash_to_base(session)),
         {:ok, _commit} <- tag(:candidate_commit, commit_tree(session, nil)),
         {:ok, base} <- tag(:base_tip, current_base(session)) do
      case prepare_candidate(session, base, force_check) do
        {:ok, updated} -> finish_commit(updated)
        {:error, updated, failure} -> fail(updated, :commit, failure)
      end
    else
      {:error, :base_moved} ->
        {:base_moved, session}

      {:error, %Failure{} = failure} ->
        fail(session, :commit, failure)

      {:error, reason} ->
        fail(session, :commit, candidate_failure(:rebase_or_commit_failed, inspect(reason)))
    end
  end

  defp finish_commit(session) do
    with {:ok, tree} <- tag(:tree_hash, Guard.tree_hash(session.workdir, session.git_env)),
         {:ok, commit} <-
           tag(:candidate_commit, Workspace.rev_parse(session.workdir, "HEAD", session.git_env)),
         {:ok, committed_tree} <-
           tag(
             :candidate_tree,
             Workspace.rev_parse(session.workdir, "#{commit}^{tree}", session.git_env)
           ),
         :ok <- tag(:tree_match, same_tree(tree, committed_tree)),
         :ok <- tag(:commit_receipt, record_commit(session, commit, tree)) do
      {:ok, %{session | failure: nil, failure_text: nil},
       [{:stage_ok, :commit, landing_identity(session, tree, commit)}]}
    else
      {:error, %Failure{} = failure} ->
        fail(session, :commit, failure)

      {:error, reason} ->
        fail(session, :commit, candidate_failure(:rebase_or_commit_failed, inspect(reason)))
    end
  end

  defp squash_to_base(session) do
    case Workspace.rev_parse(session.workdir, "HEAD", session.git_env) do
      {:ok, sha} when sha == session.base_sha -> :ok
      {:ok, _sha} -> Workspace.reset_soft(session.workdir, session.base_sha, session.git_env)
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_tree(session, _tree) do
    trailers = [{"Kogen-Intent", session.intent.slug}]

    Workspace.commit(session.workdir, session.intent.title, trailers, session.git_env)
  end

  defp current_base(session) do
    session.request.origin
    |> Workspace.ref_read(
      "refs/heads/#{session.request.base}",
      session.git_env
    )
    |> case do
      {:ok, base_sha} -> {:ok, base_sha}
      {:error, :missing} -> {:error, :base_moved}
      {:error, reason} -> {:error, reason}
    end
  end

  # The :check stage already verified this unchanged base/tree pair.
  defp prepare_candidate(session, base, false) when base == session.base_sha, do: {:ok, session}

  defp prepare_candidate(session, base, true) when base == session.base_sha,
    do: verify_rebased(session)

  defp prepare_candidate(session, base, _force_check) do
    with {:ok, manifest, drift} <-
           Workspace.refresh_manifest(
             session.request.origin,
             base,
             session.approval,
             session.git_env
           ),
         :ok <- Kogen.Engine.Build.RunEvents.base_drift(session.run, drift, base) do
      updated = %{
        session
        | base_sha: base,
          approval: %{session.approval | protected_manifest: manifest}
      }

      rebase(updated, base)
    else
      {:error, {:approved_protected_file_changed, path}} ->
        {:error, session,
         candidate_failure(
           :approved_acceptance_changed,
           "Approved acceptance test #{path} changed on the base after approval."
         )}

      {:error, reason} ->
        {:error, session,
         %Failure{class: :controller, reason: :workspace_failed, detail: inspect(reason)}}
    end
  end

  defp rebase(session, base) do
    case Workspace.rebase(session.workdir, session.request.origin, base, session.git_env) do
      :ok ->
        verify_rebased(session)

      {:error, reason} ->
        {:error, session,
         candidate_failure(:rebase_conflict, "Rebase onto #{base} failed: #{inspect(reason)}")}
    end
  end

  defp verify_rebased(session) do
    with {:ok, project} <- Kogen.Project.load(session.workdir),
         updated = %{session | project: project},
         {:ok, tree} <- Guard.tree_hash(updated.workdir, updated.git_env) do
      case recheck(updated, tree) do
        {:ok, receipts, ledger} ->
          {:ok, %{updated | receipts: receipts, acceptance: ledger}}

        {:error, %Failure{} = failure} ->
          {:error, updated, failure}

        {:error, reason} ->
          {:error, updated, candidate_failure(:verification_failed, inspect(reason))}
      end
    else
      {:error, reason} ->
        {:error, session, candidate_failure(:verification_failed, inspect(reason))}
    end
  end

  defp recheck(session, expected_tree) do
    with :ok <- guard(session),
         {:ok, checks, acceptance} <- CheckStage.verify(session),
         :ok <- CheckStage.passed(session, checks, acceptance),
         {:ok, tree} <- Guard.tree_hash(session.workdir, session.git_env),
         :ok <- same_tree(expected_tree, tree) do
      {:ok, checks.receipts, acceptance.ledger}
    end
  end

  defp guard(session) do
    Guard.check(
      session.workdir,
      session.base_sha,
      session.intent,
      session.project,
      session.approval.protected_manifest,
      session.git_env
    )
  end

  defp same_tree(tree, tree), do: :ok
  defp same_tree(_expected, _actual), do: {:error, :tree_mutated}

  defp landing_identity(session, tree, commit) do
    %{
      approval_commit: session.approval_commit,
      run_id: session.run.id,
      expected_parent: session.base_sha,
      final_tree: tree,
      candidate_commit: commit
    }
  end

  defp record_commit(session, commit, tree),
    do: State.record(session.run, %{event: :commit_result, commit: commit, tree: tree})

  @spec tag(atom(), term()) :: term()
  defp tag(_operation, {:ok, _value} = result), do: result
  defp tag(_operation, :ok), do: :ok
  defp tag(_operation, {:error, :base_moved} = result), do: result
  defp tag(_operation, {:error, %Failure{}} = result), do: result
  defp tag(operation, {:error, reason}), do: {:error, {operation, reason}}

  defp fail(session, stage, %Failure{} = failure) do
    event = %{
      event: :stage_failure,
      stage: stage,
      class: failure.class,
      reason: failure.reason,
      detail: failure.detail
    }

    case State.record(session.run, event) do
      :ok ->
        {:error, %{session | failure: failure, failure_text: failure.detail}, failure}

      {:error, reason} ->
        controller = %Failure{
          class: :controller,
          reason: :state_write_failed,
          detail: inspect(reason)
        }

        {:error, %{session | failure: controller, failure_text: controller.detail}, controller}
    end
  end

  defp candidate_failure(reason, detail),
    do: %Failure{class: :candidate, reason: reason, detail: detail}
end
