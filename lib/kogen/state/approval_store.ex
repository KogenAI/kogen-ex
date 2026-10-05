defmodule Kogen.State.ApprovalStore do
  @moduledoc false

  alias Kogen.State.Approval
  alias Kogen.State.Json

  @approval_ref_prefix "refs/kogen/intents/"
  @approval_json "approval.json"

  @spec approve(term(), Approval.t(), map(), module()) :: {:ok, String.t()} | {:error, term()}
  def approve(repo, %Approval{} = approval, git_env, workspace) when is_map(git_env) do
    with :ok <- validate(approval),
         {:ok, files} <- package_files(approval),
         {:ok, parent} <- existing_parent(repo, approval.slug, git_env, workspace),
         {:ok, sha} <- commit_package(repo, files, parent, approval, git_env, workspace),
         :ok <- move_approval_ref(repo, approval.slug, sha, parent, git_env, workspace) do
      {:ok, sha}
    end
  end

  @spec read(term(), String.t(), map(), module()) :: {:ok, Approval.t()} | {:error, term()}
  def read(repo, slug, git_env, workspace) when is_binary(slug) and is_map(git_env) do
    ref = @approval_ref_prefix <> slug

    with true <- valid_slug?(slug),
         {:ok, sha} <- workspace_call(workspace, :ref_read, [repo, ref, git_env]),
         {:ok, record_bytes} <-
           workspace_call(workspace, :read_file_at, [repo, sha, approval_path(slug), git_env]),
         {:ok, approval_record, acceptance_paths} <- Json.decode_approval(record_bytes, slug),
         {:ok, approval} <-
           reconstruct(repo, sha, approval_record, acceptance_paths, git_env, workspace) do
      {:ok, approval}
    else
      false -> {:error, :invalid_slug}
      {:error, :missing} -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate(Approval.t()) :: :ok | {:error, atom()}
  def validate(%Approval{} = approval) do
    with :ok <- validate_intent(approval),
         :ok <- validate_fields(approval),
         :ok <- validate_acceptance_files(approval) do
      with :ok <- validate_manifest(approval.protected_manifest) do
        validate_check_baseline(approval.check_baseline)
      end
    end
  end

  defp validate_intent(%Approval{intent_bytes: bytes} = approval) when is_binary(bytes) do
    hash = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    require_valid(hash == approval.intent_sha256, :intent_hash_mismatch)
  end

  defp validate_intent(_approval), do: {:error, :invalid_intent_bytes}

  defp validate_fields(approval) do
    with :ok <- require_valid(valid_slug?(approval.slug), :invalid_slug),
         :ok <- require_valid(valid_single_line?(approval.target_branch), :invalid_target_branch),
         :ok <- require_valid(valid_single_line?(approval.base_sha), :invalid_base_sha),
         :ok <- validate_domains(approval.domains),
         :ok <- require_valid(valid_single_line?(approval.by), :invalid_approver) do
      require_valid(match?(%DateTime{}, approval.at), :invalid_approval_time)
    end
  end

  defp validate_domains(domains) when is_list(domains) do
    require_valid(Enum.all?(domains, &valid_single_line?/1), :invalid_domains)
  end

  defp validate_domains(_domains), do: {:error, :invalid_domains}

  defp validate_acceptance_files(%Approval{} = approval) do
    reserved = [intent_path(approval.slug), approval_path(approval.slug)]

    if is_map(approval.acceptance_files) and valid_files?(approval.acceptance_files, reserved),
      do: :ok,
      else: {:error, :invalid_acceptance_path}
  end

  defp validate_manifest(manifest) when is_map(manifest) do
    if valid_manifest?(manifest), do: :ok, else: {:error, :invalid_protected_manifest}
  end

  defp validate_manifest(_manifest), do: {:error, :invalid_protected_manifest}

  defp validate_check_baseline(rows) when is_list(rows) do
    valid =
      Enum.all?(rows, fn
        %{name: name, status: status, findings: findings}
        when is_binary(name) and name != "" and status in [:green, :red] and is_list(findings) ->
          (status == :red or findings == []) and Enum.all?(findings, &valid_check_finding?/1)

        _row ->
          false
      end)

    require_valid(valid, :invalid_check_baseline)
  end

  defp validate_check_baseline(_rows), do: {:error, :invalid_check_baseline}

  defp valid_check_finding?(%{path: path, kind: kind, id: id, tool: tool, message: message}) do
    (is_nil(path) or safe_repo_path?(path)) and kind in [:rule, :test] and
      valid_single_line?(id) and valid_single_line?(tool) and is_binary(message) and
      not String.contains?(message, ["\n", "\r"])
  end

  defp valid_check_finding?(_finding), do: false

  defp require_valid(true, _reason), do: :ok
  defp require_valid(false, reason), do: {:error, reason}

  defp package_files(approval) do
    with {:ok, encoded} <- Json.encode_approval(approval) do
      files =
        approval.acceptance_files
        |> Map.put(intent_path(approval.slug), approval.intent_bytes)
        |> Map.put(approval_path(approval.slug), encoded)

      {:ok, files}
    end
  end

  defp existing_parent(repo, slug, git_env, workspace) do
    case workspace_call(workspace, :ref_read, [repo, @approval_ref_prefix <> slug, git_env]) do
      {:ok, sha} -> {:ok, [sha]}
      {:error, :missing} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_package(repo, files, parents, approval, git_env, workspace) do
    message = Json.approval_message(approval)

    workspace_call(workspace, :commit_tree_with_files, [
      repo,
      files,
      parents,
      message,
      git_env
    ])
  end

  defp move_approval_ref(repo, slug, sha, [], git_env, workspace) do
    workspace_call(workspace, :ref_create, [repo, @approval_ref_prefix <> slug, sha, git_env])
  end

  defp move_approval_ref(repo, slug, sha, [old], git_env, workspace) do
    workspace_call(workspace, :ref_update, [repo, @approval_ref_prefix <> slug, sha, old, git_env])
  end

  defp reconstruct(repo, sha, %Approval{} = approval, acceptance_paths, git_env, workspace) do
    with {:ok, intent_bytes} <-
           read_file(repo, sha, intent_path(approval.slug), git_env, workspace),
         {:ok, acceptance_files} <-
           read_acceptance_files(repo, sha, acceptance_paths, git_env, workspace),
         {:ok, message} <- workspace_call(workspace, :commit_message, [repo, sha, git_env]),
         :ok <- Json.verify_approval_trailers(message, approval),
         approval = %{approval | intent_bytes: intent_bytes, acceptance_files: acceptance_files},
         :ok <- validate(approval) do
      {:ok, approval}
    end
  end

  defp read_file(repo, sha, path, git_env, workspace) do
    workspace_call(workspace, :read_file_at, [repo, sha, path, git_env])
  end

  defp read_acceptance_files(repo, sha, paths, git_env, workspace) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, files} ->
      case read_file(repo, sha, path, git_env, workspace) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(files, path, bytes)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp valid_files?(files, reserved) do
    Enum.all?(files, fn {path, bytes} ->
      safe_repo_path?(path) and is_binary(bytes) and path not in reserved
    end)
  end

  defp valid_manifest?(manifest) do
    Enum.all?(manifest, fn {path, digest} ->
      safe_repo_path?(path) and is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
    end)
  end

  defp safe_repo_path?(path) when is_binary(path) do
    parts = String.split(path, "/")

    Path.type(path) == :relative and path != "" and
      Enum.all?(parts, &(&1 not in ["", ".", "..", ".git"]))
  end

  defp safe_repo_path?(_path), do: false

  defp valid_single_line?(value) when is_binary(value) do
    value != "" and not String.contains?(value, ["\n", "\r"])
  end

  defp valid_single_line?(_value), do: false

  defp valid_slug?(slug) do
    is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
  end

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
  defp approval_path(slug), do: ".kogen/intents/#{slug}/#{@approval_json}"

  defp workspace_call(workspace, function, arguments), do: apply(workspace, function, arguments)
end
