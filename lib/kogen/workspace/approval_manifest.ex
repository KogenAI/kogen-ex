defmodule Kogen.Workspace.ApprovalManifest do
  @moduledoc false

  alias Kogen.Contracts.Stack
  alias Kogen.Workspace

  @spec unchanged_between(Path.t(), String.t(), String.t(), map(), map()) ::
          :ok | {:error, term()}
  def unchanged_between(origin, approved_sha, current_sha, manifest, git_env) do
    manifest
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      with {:ok, approved_file} <- file_at(origin, approved_sha, path, git_env),
           {:ok, current_file} <- file_at(origin, current_sha, path, git_env) do
        if approved_file == current_file do
          {:cont, :ok}
        else
          {:halt, {:error, {:approved_protected_file_changed, path}}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec build_base(Path.t(), String.t(), map(), map()) ::
          {:ok, String.t(), map(), [String.t()]} | {:error, term()}
  def build_base(origin, branch, approval, git_env) do
    with {:ok, current} <- Workspace.ref_read(origin, "refs/heads/#{branch}", git_env),
         {:ok, manifest, drift} <- refresh(origin, current, approval, git_env) do
      {:ok, current, manifest, drift}
    end
  end

  @spec refresh(Path.t(), String.t(), map(), map()) ::
          {:ok, map(), [String.t()]} | {:error, term()}
  def refresh(origin, current, approval, git_env) do
    acceptance =
      Map.keys(approval.acceptance_files) ++
        Map.keys(Stack.installed_files(approval.acceptance_files))

    with :ok <-
           unchanged_between(
             origin,
             approval.base_sha,
             current,
             Map.from_keys(acceptance, nil),
             git_env
           ) do
      own = [".kogen/intents/#{approval.slug}/intent.md" | acceptance]
      refresh_paths(origin, current, approval.protected_manifest, own, git_env)
    end
  end

  defp refresh_paths(origin, current, manifest, own, git_env) do
    manifest
    |> Enum.reject(fn {path, _hash} -> path in own end)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, manifest, []}, fn {path, old}, {:ok, updated, drift} ->
      case file_at(origin, current, path, git_env) do
        {:ok, file} ->
          hash = digest(file)
          drift = if hash == old, do: drift, else: drift ++ [path]
          {:cont, {:ok, Map.put(updated, path, hash), drift}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp digest(:missing), do: Workspace.absent_digest()

  defp digest({:present, bytes}),
    do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp file_at(origin, revision, path, git_env) do
    case Workspace.read_file_at(origin, revision, path, git_env) do
      {:ok, bytes} -> {:ok, {:present, bytes}}
      {:error, :missing} -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end
end
