defmodule Kogen.State.Lifecycle do
  @moduledoc false

  alias Kogen.State.ApprovalStore
  alias Kogen.State.Json
  alias Kogen.State.Run
  alias Kogen.State.RunStore

  @claim_ref "refs/kogen/claim"
  @claim_path ".kogen/claim"

  @spec claim(term(), String.t(), map(), module()) :: :ok | {:error, term()}
  def claim(repo, run_id, git_env, workspace) when is_binary(run_id) and is_map(git_env) do
    if valid_run_id?(run_id) do
      with {:ok, sha} <- claim_commit(repo, run_id, git_env, workspace) do
        case workspace_call(workspace, :ref_create, [repo, @claim_ref, sha, git_env]) do
          :ok -> :ok
          {:error, :exists} -> claimed_result(repo, git_env, workspace)
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, :invalid_run_id}
    end
  end

  @spec release(term(), String.t(), map(), module()) :: :ok | {:error, term()}
  def release(repo, run_id, git_env, workspace) when is_binary(run_id) and is_map(git_env) do
    case workspace_call(workspace, :ref_read, [repo, @claim_ref, git_env]) do
      {:ok, sha} ->
        with {:ok, message} <- workspace_call(workspace, :commit_message, [repo, sha, git_env]),
             ^run_id <- Json.claim_run_id(message) do
          workspace_call(workspace, :ref_delete, [repo, @claim_ref, sha, git_env])
        else
          nil -> {:error, :not_owner}
          {:error, reason} -> {:error, reason}
          _other -> {:error, :not_owner}
        end

      {:error, :missing} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec status(term(), Path.t(), String.t(), String.t(), map(), module()) :: Kogen.State.status()
  def status(repo, root, slug, branch, git_env, workspace) do
    runs = root |> RunStore.list() |> state!() |> Enum.filter(&(&1.slug == slug))

    if landed?(repo, slug, branch, git_env, workspace),
      do: :landed,
      else: unlanded_status(repo, slug, runs, git_env, workspace)
  end

  @spec reconcile(term(), Path.t(), Run.t(), String.t(), map(), module()) ::
          {:ok, :landed | :unchanged} | {:error, term()}
  def reconcile(repo, root, %Run{} = run, branch, git_env, workspace) do
    with {:ok, current} <- RunStore.load(root, run.id) do
      case current.landing do
        nil ->
          {:ok, :unchanged}

        landing ->
          reconcile_landing(repo, current, landing, branch, git_env, workspace)
      end
    end
  end

  @spec recover_crashed(term(), Path.t(), Run.t(), map(), module(), :crashed | :interrupted) ::
          :ok | {:error, term()}
  def recover_crashed(repo, root, %Run{} = run, git_env, workspace, reason \\ :crashed) do
    with {:ok, current} <- RunStore.load(root, run.id) do
      case current.status do
        :running ->
          with :ok <-
                 RunStore.record(current, %{event: :finished, status: :failed, reason: reason}) do
            release(repo, current.id, git_env, workspace)
          end

        _terminal ->
          :ok
      end
    end
  end

  defp claim_commit(repo, run_id, git_env, workspace) do
    message = Json.claim_message(run_id)
    files = Map.new([{@claim_path, run_id}])

    workspace_call(workspace, :commit_tree_with_files, [
      repo,
      files,
      [],
      message,
      git_env
    ])
  end

  defp claimed_result(repo, git_env, workspace) do
    case workspace_call(workspace, :ref_read, [repo, @claim_ref, git_env]) do
      {:ok, sha} ->
        with {:ok, message} <- workspace_call(workspace, :commit_message, [repo, sha, git_env]),
             run_id when is_binary(run_id) <- Json.claim_run_id(message) do
          {:error, {:claimed, run_id}}
        else
          {:error, reason} -> {:error, reason}
          _missing -> {:error, :invalid_claim}
        end

      {:error, :missing} ->
        {:error, :claim_raced}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_landing(repo, run, landing, branch, git_env, workspace) do
    case workspace_call(workspace, :rev_parse, [repo, branch_ref(branch), git_env]) do
      {:ok, branch_sha} ->
        case workspace_call(workspace, :ancestor?, [
               repo,
               landing.candidate_commit,
               branch_sha,
               git_env
             ]) do
          true ->
            with :ok <- RunStore.record(run, %{event: :reconciled, status: :landed}),
                 :ok <- release_after_landing(repo, run.id, git_env, workspace) do
              {:ok, :landed}
            end

          false ->
            {:ok, :unchanged}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :missing} ->
        {:ok, :unchanged}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_after_landing(repo, run_id, git_env, workspace) do
    case release(repo, run_id, git_env, workspace) do
      {:error, :not_owner} -> :ok
      result -> result
    end
  end

  defp landed?(repo, slug, branch, git_env, workspace) do
    case workspace_call(workspace, :intent_commit, [repo, branch, slug, git_env]) do
      {:ok, sha} -> is_binary(sha)
      {:error, reason} -> raise ArgumentError, "cannot inspect target branch: #{inspect(reason)}"
    end
  end

  defp terminal_for_approval?(runs, approval_sha, status) when is_binary(approval_sha) do
    Enum.any?(runs, &(&1.approval_commit == approval_sha and &1.status == status))
  end

  defp terminal_for_approval?(_runs, _approval_sha, _status), do: false

  defp unlanded_status(repo, slug, runs, git_env, workspace) do
    current_approval = ref_value!(repo, "refs/kogen/intents/#{slug}", git_env, workspace)
    if current_approval, do: validate_approval!(repo, slug, git_env, workspace)

    cond do
      claimed_run?(repo, runs, git_env, workspace) ->
        :building

      terminal_for_approval?(runs, current_approval, :parked) ->
        :parked

      terminal_for_approval?(runs, current_approval, :failed) ->
        :failed

      current_approval != nil ->
        :approved

      true ->
        :draft
    end
  end

  defp claimed_run?(repo, runs, git_env, workspace) do
    case ref_value!(repo, @claim_ref, git_env, workspace) do
      nil ->
        false

      sha ->
        with {:ok, message} <- workspace_call(workspace, :commit_message, [repo, sha, git_env]),
             run_id when is_binary(run_id) <- Json.claim_run_id(message) do
          Enum.any?(runs, &(&1.id == run_id))
        else
          {:error, reason} ->
            raise ArgumentError, "cannot inspect project claim: #{inspect(reason)}"

          _invalid ->
            raise ArgumentError, "project claim is malformed"
        end
    end
  end

  defp validate_approval!(repo, slug, git_env, workspace) do
    case ApprovalStore.read(repo, slug, git_env, workspace) do
      {:ok, _approval} -> :ok
      {:error, reason} -> raise ArgumentError, "invalid approval package: #{inspect(reason)}"
    end
  end

  defp ref_value!(repo, ref, git_env, workspace) do
    case workspace_call(workspace, :ref_read, [repo, ref, git_env]) do
      {:ok, sha} -> sha
      {:error, :missing} -> nil
      {:error, reason} -> raise ArgumentError, "cannot read Kogen ref: #{inspect(reason)}"
    end
  end

  defp state!({:ok, state}), do: state
  defp state!({:error, reason}), do: raise(ArgumentError, "cannot read State: #{inspect(reason)}")

  defp branch_ref("refs/heads/" <> _branch = ref), do: ref
  defp branch_ref(branch), do: "refs/heads/" <> branch

  defp valid_run_id?(run_id), do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/, run_id)

  defp workspace_call(workspace, function, arguments), do: apply(workspace, function, arguments)
end
