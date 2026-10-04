defmodule Kogen.Engine.Build.Commit do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.Guard
  alias Kogen.Engine.Build.Session
  alias Kogen.State
  alias Kogen.Workspace

  @spec run(Session.t()) ::
          {:ok, Session.t(), [term()]}
          | {:error, Session.t(), Failure.t()}
          | {:base_moved, Session.t()}
  def run(%Session{} = session) do
    with {:ok, tree} <- tag(:tree_hash, Guard.tree_hash(session.workdir, session.git_env)),
         :ok <- tag(:squash, squash_to_base(session)),
         {:ok, commit} <- tag(:candidate_commit, commit_tree(session, tree)),
         {:ok, base_sha} <- tag(:base_tip, current_base(session)),
         {:ok, session, commit, tree} <- prepare_candidate(session, base_sha, commit, tree),
         {:ok, committed_tree} <-
           tag(
             :candidate_tree,
             Workspace.rev_parse(session.workdir, "#{commit}^{tree}", session.git_env)
           ),
         :ok <- tag(:tree_match, same_tree(tree, committed_tree)),
         :ok <- tag(:commit_receipt, record_commit(session, commit, tree)) do
      identity = landing_identity(session, tree, commit)
      session = %{session | failure: nil, failure_text: nil}
      {:ok, session, [{:stage_ok, :commit, identity}]}
    else
      {:error, :base_moved} ->
        {:base_moved, session}

      {:error, %Failure{} = failure} ->
        fail(session, :commit, failure)

      {:error, reason} ->
        fail(session, :commit, candidate_failure(:rebase_or_commit_failed, inspect(reason)))
    end
  end

  @spec land(map(), Session.t()) ::
          {:ok, Session.t(), [term()]}
          | {:error, Session.t(), Failure.t()}
          | {:base_moved, Session.t()}
  def land(args, %Session{} = session) do
    expected = Map.fetch!(args, :expected_parent)
    candidate = Map.fetch!(args, :candidate_commit)

    case Workspace.land(
           session.workdir,
           session.request.origin,
           session.request.base,
           expected,
           session.run.id,
           session.git_env
         ) do
      :ok ->
        {:ok, %{session | landed_sha: candidate}, [{:landed, candidate}]}

      {:error, :base_moved} ->
        {:base_moved, session}

      {:error, reason} ->
        fail(session, :land, candidate_failure(:landing_failed, inspect(reason)))
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
  defp prepare_candidate(session, base_sha, commit, tree) when base_sha == session.base_sha do
    {:ok, session, commit, tree}
  end

  defp prepare_candidate(session, base_sha, _commit, _tree) do
    case Workspace.rebase(session.workdir, session.request.origin, base_sha, session.git_env) do
      :ok ->
        session = %{session | base_sha: base_sha}

        with {:ok, commit} <-
               tag(
                 :candidate_commit,
                 Workspace.rev_parse(session.workdir, "HEAD", session.git_env)
               ),
             {:ok, tree} <- tag(:tree_hash, Guard.tree_hash(session.workdir, session.git_env)),
             {:ok, receipts, ledger} <- verify_rebased(session, tree) do
          session = %{session | receipts: receipts, acceptance: ledger}
          {:ok, session, commit, tree}
        end

      {:error, _reason} ->
        {:error, :base_moved}
    end
  end

  defp verify_rebased(session, tree) do
    case recheck(session, tree) do
      {:error, %Failure{reason: :verification_failed}} -> {:error, :base_moved}
      result -> tag(:recheck, result)
    end
  end

  defp recheck(session, expected_tree) do
    with :ok <- guard(session),
         {:ok, checks} <-
           Kogen.Checks.run_all(
             session.workdir,
             session.project,
             session.run_dir,
             session.process_env,
             session.git_env,
             session.sandbox
           ),
         {:ok, acceptance} <-
           Kogen.Checks.acceptance(
             session.workdir,
             session.intent,
             session.run_dir,
             session.process_env,
             session.git_env,
             session.sandbox
           ),
         :ok <- record_check_results(session, checks, acceptance),
         :ok <- check_passed(checks, acceptance),
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

  defp check_passed(%{status: :pass}, %{status: :pass}), do: :ok

  defp check_passed(checks, acceptance) do
    feedback = Map.get(checks, :feedback, "")

    detail =
      if feedback == "" do
        "checks=#{inspect(checks.status)} acceptance=#{inspect(acceptance.status)}"
      else
        feedback <> "\nacceptance=#{inspect(acceptance.status)}"
      end

    {:error, candidate_failure(:verification_failed, detail)}
  end

  defp record_check_results(session, checks, acceptance) do
    with :ok <-
           State.record(session.run, %{
             event: :check_result,
             result: checks.status,
             receipts: checks.receipts
           }) do
      State.record(session.run, %{
        event: :acceptance_result,
        result: acceptance_status(acceptance.status),
        ledger: acceptance.ledger
      })
    end
  end

  defp acceptance_status(:pass), do: :pass
  defp acceptance_status({:fail, ids}), do: %{status: :fail, failed_ids: ids}

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

  @spec tag(
          atom(),
          {:ok, term()}
          | {:ok, term(), term()}
          | :ok
          | {:error, :base_moved | Failure.t() | term()}
        ) ::
          {:ok, term()}
          | {:ok, term(), term()}
          | :ok
          | {:error, :base_moved | Failure.t() | {atom(), term()}}
  defp tag(_operation, {:ok, _value} = result), do: result
  defp tag(_operation, {:ok, _value, _extra} = result), do: result
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
