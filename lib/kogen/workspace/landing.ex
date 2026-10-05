defmodule Kogen.Workspace.Landing do
  @moduledoc false

  alias Kogen.Workspace.CheckedOut
  alias Kogen.Workspace.Checkout
  alias Kogen.Workspace.Git
  alias Kogen.Workspace.Refs

  @spec land(Path.t(), Path.t(), String.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, [CheckedOut.warning()]} | {:error, term()}
  def land(path, origin, branch, expected_old_sha, run_id, git_env) do
    branch_ref = "refs/heads/#{branch}"
    incoming_ref = "refs/kogen/incoming/#{run_id}"

    with :ok <- validate_inputs(path, origin, branch, run_id, git_env),
         :ok <- branch_unlocked(origin, branch_ref),
         {:ok, checkouts} <- CheckedOut.worktrees(origin, branch, git_env),
         :ok <- origin_at_expected(origin, branch_ref, expected_old_sha, git_env),
         {:ok, new_sha} <- head_sha(path, git_env),
         :ok <- single_expected_parent(path, new_sha, expected_old_sha, git_env),
         :ok <- commit_tree_matches_working_tree(path, new_sha, git_env),
         :ok <- ref_missing(origin, incoming_ref, git_env),
         :ok <- push_incoming(path, origin, new_sha, incoming_ref, git_env) do
      target = %{
        branch: branch,
        branch_ref: branch_ref,
        incoming_ref: incoming_ref,
        checkouts: checkouts
      }

      land_pushed(origin, target, new_sha, expected_old_sha, git_env)
    end
  end

  @spec park(Path.t(), Path.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  def park(path, origin, run_id, git_env) do
    parked_ref = "refs/kogen/parked/#{run_id}"

    with :ok <- validate_park(path, origin, run_id),
         :ok <- ref_missing(origin, parked_ref, git_env),
         {:ok, head} <- head_sha(path, git_env),
         :ok <- push_incoming(path, origin, head, parked_ref, git_env) do
      Checkout.destroy(path)
    end
  end

  @spec validate_inputs(Path.t(), Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp validate_inputs(path, origin, branch, run_id, git_env) do
    with true <- absolute_directory?(path) and absolute_directory?(origin),
         true <- valid_branch?(branch) and Git.safe_build_id?(run_id),
         :ok <- valid_branch_ref(origin, branch, git_env) do
      :ok
    else
      false -> {:error, :invalid_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_park(Path.t(), Path.t(), String.t()) :: :ok | {:error, atom()}
  defp validate_park(path, origin, run_id) do
    if absolute_directory?(path) and Git.valid_worktree_path?(path) and
         absolute_directory?(origin) and
         Git.safe_build_id?(run_id) do
      :ok
    else
      {:error, :invalid_path}
    end
  end

  @spec ref_missing(Path.t(), String.t(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  defp ref_missing(repo, ref, git_env) do
    case Refs.ref_read(repo, ref, git_env) do
      {:error, :missing} -> :ok
      {:ok, _sha} -> {:error, :ref_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec absolute_directory?(Path.t()) :: boolean()
  defp absolute_directory?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.dir?(path)

  @spec valid_branch?(String.t()) :: boolean()
  defp valid_branch?(branch), do: Git.safe_relative_path?(branch)

  @spec valid_branch_ref(Path.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, :invalid_branch | term()}
  defp valid_branch_ref(origin, branch, git_env) do
    case Git.run(origin, ["check-ref-format", "refs/heads/#{branch}"], git_env) do
      {:ok, 0, _output} -> :ok
      {:ok, _status, _output} -> {:error, :invalid_branch}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec branch_unlocked(Path.t(), String.t()) :: :ok | {:error, :ref_locked}
  defp branch_unlocked(origin, branch_ref) do
    lock_path = Path.join(Git.git_dir(origin), branch_ref <> ".lock")
    if File.exists?(lock_path), do: {:error, :ref_locked}, else: :ok
  end

  @spec origin_at_expected(Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, :base_moved | term()}
  defp origin_at_expected(origin, branch_ref, expected, git_env) do
    case Refs.ref_read(origin, branch_ref, git_env) do
      {:ok, ^expected} -> :ok
      {:ok, _current} -> {:error, :base_moved}
      {:error, :missing} -> {:error, :base_moved}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec head_sha(Path.t(), %{String.t() => String.t()}) :: {:ok, String.t()} | {:error, term()}
  defp head_sha(path, git_env) do
    case Git.run(path, ["rev-parse", "--verify", "HEAD"], git_env) do
      {:ok, 0, output} -> {:ok, Git.trim_line(output)}
      {:ok, _status, _output} -> {:error, :missing_head}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec single_expected_parent(Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, :not_fast_forward | term()}
  defp single_expected_parent(path, new_sha, expected_parent, git_env) do
    case Git.run(path, ["rev-list", "--parents", "-n", "1", new_sha], git_env) do
      {:ok, 0, output} ->
        case String.split(String.trim(output)) do
          [^new_sha, parent] when parent == expected_parent -> :ok
          _parents -> {:error, :not_fast_forward}
        end

      {:ok, _status, _output} ->
        {:error, :not_fast_forward}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec commit_tree_matches_working_tree(Path.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, :tree_mismatch | term()}
  defp commit_tree_matches_working_tree(path, commit, git_env) do
    with {:ok, working_tree} <- Checkout.tree_hash(path, git_env),
         {:ok, committed_tree} <- Refs.rev_parse(path, "#{commit}^{tree}", git_env) do
      if working_tree == committed_tree, do: :ok, else: {:error, :tree_mismatch}
    end
  end

  @spec push_incoming(Path.t(), Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, term()}
  defp push_incoming(path, origin, sha, destination_ref, git_env) do
    case Git.run(path, ["push", "--quiet", origin, "#{sha}:#{destination_ref}"], git_env) do
      {:ok, 0, _output} -> :ok
      {:ok, _status, _output} -> {:error, :push_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec land_pushed(Path.t(), map(), String.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, [CheckedOut.warning()]} | {:error, term()}
  defp land_pushed(origin, target, new_sha, expected_old_sha, git_env) do
    %{branch: branch, branch_ref: branch_ref, incoming_ref: incoming_ref} = target

    cas_result =
      Git.run(
        origin,
        ["update-ref", "--no-deref", branch_ref, new_sha, expected_old_sha],
        git_env
      )

    cas_outcome = cas_outcome(origin, branch_ref, cas_result)

    warnings =
      if cas_outcome == :ok,
        do: CheckedOut.update(target.checkouts, branch, expected_old_sha, new_sha, git_env),
        else: []

    delete_outcome = delete_temp_ref(origin, incoming_ref, new_sha, git_env)

    case {cas_outcome, delete_outcome} do
      {:ok, :ok} -> {:ok, warnings}
      {{:error, _reason} = error, :ok} -> error
      {_result, {:error, _reason} = error} -> error
    end
  end

  @spec cas_outcome(Path.t(), String.t(), term()) ::
          :ok | {:error, :base_moved | :ref_locked | term()}
  defp cas_outcome(_origin, _branch_ref, {:ok, 0, _output}), do: :ok

  defp cas_outcome(origin, branch_ref, {:ok, _status, _output}) do
    lock_path = Path.join(Git.git_dir(origin), branch_ref <> ".lock")
    if File.exists?(lock_path), do: {:error, :ref_locked}, else: {:error, :base_moved}
  end

  defp cas_outcome(_origin, _branch_ref, {:error, reason}), do: {:error, reason}

  @spec delete_temp_ref(Path.t(), String.t(), String.t(), %{String.t() => String.t()}) ::
          :ok | {:error, :cleanup_failed}
  defp delete_temp_ref(origin, incoming_ref, new_sha, git_env) do
    case Refs.ref_delete(origin, incoming_ref, new_sha, git_env) do
      :ok -> :ok
      {:error, _reason} -> {:error, :cleanup_failed}
    end
  end
end
